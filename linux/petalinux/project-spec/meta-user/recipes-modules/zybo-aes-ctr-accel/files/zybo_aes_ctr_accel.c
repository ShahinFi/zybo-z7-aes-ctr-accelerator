// SPDX-License-Identifier: GPL-2.0
/*
 * Zybo Z7 AES-CTR FPGA accelerator platform driver.
 *
 * Hardware path:
 *   AXI DMA MM2S -> aes_ctr_block_128 -> AXI DMA S2MM
 *
 * AXI-Lite register map:
 *   0x00 VERSION
 *   0x04 SCRATCH
 *   0x08 AES_CONTROL          bit 0 = start pulse
 *   0x0c AES_STATUS           bit 0 = idle, bit 1 = busy
 *   0x10 AES_KEY_0            key[127:96]
 *   0x14 AES_KEY_1            key[95:64]
 *   0x18 AES_KEY_2            key[63:32]
 *   0x1c AES_KEY_3            key[31:0]
 *   0x20 AES_NONCE_0          nonce[95:64]
 *   0x24 AES_NONCE_1          nonce[63:32]
 *   0x28 AES_NONCE_2          nonce[31:0]
 *   0x2c AES_INITIAL_COUNTER
 */

#include <linux/bits.h>
#include <linux/compat.h>
#include <linux/completion.h>
#include <linux/device.h>
#include <linux/dma-mapping.h>
#include <linux/dmaengine.h>
#include <linux/err.h>
#include <linux/fs.h>
#include <linux/io.h>
#include <linux/jiffies.h>
#include <linux/kernel.h>
#include <linux/miscdevice.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <linux/uaccess.h>


#include "zybo_aes_ctr_accel_uapi.h"

#define ZYBO_AES_CTR_DRIVER_NAME              "zybo_aes_ctr_accel"

#define ZYBO_AES_CTR_REG_VERSION              0x00U
#define ZYBO_AES_CTR_REG_CONTROL              0x08U
#define ZYBO_AES_CTR_REG_STATUS               0x0cU
#define ZYBO_AES_CTR_REG_KEY0                 0x10U
#define ZYBO_AES_CTR_REG_KEY1                 0x14U
#define ZYBO_AES_CTR_REG_KEY2                 0x18U
#define ZYBO_AES_CTR_REG_KEY3                 0x1cU
#define ZYBO_AES_CTR_REG_NONCE0               0x20U
#define ZYBO_AES_CTR_REG_NONCE1               0x24U
#define ZYBO_AES_CTR_REG_NONCE2               0x28U
#define ZYBO_AES_CTR_REG_INITIAL_COUNTER      0x2cU

#define ZYBO_AES_CTR_MIN_MMIO_SIZE            0x30U

#define ZYBO_AES_CTR_CONTROL_START            BIT(0)
#define ZYBO_AES_CTR_STATUS_IDLE              BIT(0)
#define ZYBO_AES_CTR_STATUS_BUSY              BIT(1)

#define ZYBO_AES_CTR_VERSION_V0_1             0x00010000U

#define ZYBO_AES_CTR_DMA_MAX_BYTES            (1024U * 1024U)
#define ZYBO_AES_CTR_DMA_ALIGNMENT_BYTES      4U
#define ZYBO_AES_CTR_DMA_TIMEOUT_DEFAULT      1000U
#define ZYBO_AES_CTR_DMA_TIMEOUT_MAX          60000U

struct zybo_aes_ctr_dev {
	struct device *dev;
	void __iomem *regs;
	resource_size_t regs_size;
	struct mutex lock;
	struct miscdevice miscdev;
	u32 cached_version;

	struct zybo_aes_ctr_config config;
	bool config_valid;

	struct dma_chan *tx_chan;
	struct dma_chan *rx_chan;
	struct device *tx_dma_dev;
	struct device *rx_dma_dev;
	void *tx_cpu_buf;
	void *rx_cpu_buf;
	dma_addr_t tx_dma_addr;
	dma_addr_t rx_dma_addr;
	size_t dma_buf_size;
	struct completion tx_done;
	struct completion rx_done;
	struct zybo_aes_ctr_stats stats;
};

static inline u32 zybo_aes_ctr_readl(struct zybo_aes_ctr_dev *accel, u32 offset)
{
	return readl(accel->regs + offset);
}

static inline void zybo_aes_ctr_writel(struct zybo_aes_ctr_dev *accel,
				       u32 offset, u32 value)
{
	writel(value, accel->regs + offset);
}

static void zybo_aes_ctr_fill_info(struct zybo_aes_ctr_dev *accel,
				   struct zybo_aes_ctr_accel_info *info)
{
	info->abi_version = ZYBO_AES_CTR_ACCEL_ABI_VERSION;
	info->hardware_version = accel->cached_version;
	info->register_span = accel->regs_size > 0xffffffffULL ?
		0xffffffffU : (u32)accel->regs_size;
	info->reserved = 0;
}

static void zybo_aes_ctr_fill_dma_caps(struct zybo_aes_ctr_dma_caps *caps)
{
	memset(caps, 0, sizeof(*caps));
	caps->max_transfer_bytes = ZYBO_AES_CTR_DMA_MAX_BYTES;
	caps->transfer_alignment_bytes = ZYBO_AES_CTR_DMA_ALIGNMENT_BYTES;
	caps->default_timeout_ms = ZYBO_AES_CTR_DMA_TIMEOUT_DEFAULT;
	caps->max_timeout_ms = ZYBO_AES_CTR_DMA_TIMEOUT_MAX;
	caps->flags = ZYBO_AES_CTR_DMA_CAP_BLOCKING_SUBMIT |
		      ZYBO_AES_CTR_DMA_CAP_DRIVER_STAGING_BUFS;
}

static void zybo_aes_ctr_fill_status(struct zybo_aes_ctr_dev *accel,
				     struct zybo_aes_ctr_status *status)
{
	u32 raw = zybo_aes_ctr_readl(accel, ZYBO_AES_CTR_REG_STATUS);

	memset(status, 0, sizeof(*status));
	status->status = raw;
	status->idle = !!(raw & ZYBO_AES_CTR_STATUS_IDLE);
	status->busy = !!(raw & ZYBO_AES_CTR_STATUS_BUSY);
}

static int zybo_aes_ctr_validate_config(const struct zybo_aes_ctr_config *config)
{
	u32 i;

	for (i = 0; i < ARRAY_SIZE(config->reserved); ++i) {
		if (config->reserved[i])
			return -EINVAL;
	}

	return 0;
}

static void zybo_aes_ctr_program_config(struct zybo_aes_ctr_dev *accel)
{
	zybo_aes_ctr_writel(accel, ZYBO_AES_CTR_REG_KEY0, accel->config.key_words[0]);
	zybo_aes_ctr_writel(accel, ZYBO_AES_CTR_REG_KEY1, accel->config.key_words[1]);
	zybo_aes_ctr_writel(accel, ZYBO_AES_CTR_REG_KEY2, accel->config.key_words[2]);
	zybo_aes_ctr_writel(accel, ZYBO_AES_CTR_REG_KEY3, accel->config.key_words[3]);

	zybo_aes_ctr_writel(accel, ZYBO_AES_CTR_REG_NONCE0, accel->config.nonce_words[0]);
	zybo_aes_ctr_writel(accel, ZYBO_AES_CTR_REG_NONCE1, accel->config.nonce_words[1]);
	zybo_aes_ctr_writel(accel, ZYBO_AES_CTR_REG_NONCE2, accel->config.nonce_words[2]);

	zybo_aes_ctr_writel(accel, ZYBO_AES_CTR_REG_INITIAL_COUNTER,
			    accel->config.initial_counter);

	(void)zybo_aes_ctr_readl(accel, ZYBO_AES_CTR_REG_STATUS);
}

static void zybo_aes_ctr_start(struct zybo_aes_ctr_dev *accel)
{
	zybo_aes_ctr_writel(accel, ZYBO_AES_CTR_REG_CONTROL,
			    ZYBO_AES_CTR_CONTROL_START);

	(void)zybo_aes_ctr_readl(accel, ZYBO_AES_CTR_REG_STATUS);
}

static void zybo_aes_ctr_dma_callback(void *done)
{
	complete(done);
}

static int zybo_aes_ctr_wait_until(struct completion *done,
				   unsigned long deadline)
{
	unsigned long remaining;

	if (time_after_eq(jiffies, deadline))
		return -ETIMEDOUT;

	remaining = deadline - jiffies;
	if (!wait_for_completion_timeout(done, remaining))
		return -ETIMEDOUT;

	return 0;
}

static void zybo_aes_ctr_terminate_dma(struct zybo_aes_ctr_dev *accel)
{
	dmaengine_terminate_sync(accel->rx_chan);
	dmaengine_terminate_sync(accel->tx_chan);
}

static int zybo_aes_ctr_validate_transfer(
	const struct zybo_aes_ctr_transfer *transfer)
{
	if (!transfer->input_ptr || !transfer->output_ptr)
		return -EINVAL;

	if (!transfer->length || transfer->length > ZYBO_AES_CTR_DMA_MAX_BYTES)
		return -EINVAL;

	if (transfer->length % ZYBO_AES_CTR_DMA_ALIGNMENT_BYTES)
		return -EINVAL;

	if (transfer->timeout_ms > ZYBO_AES_CTR_DMA_TIMEOUT_MAX)
		return -EINVAL;

	if (transfer->flags || transfer->reserved)
		return -EINVAL;

	return 0;
}

static void zybo_aes_ctr_note_transfer_result(struct zybo_aes_ctr_dev *accel,
					      u32 length, int ret)
{
	accel->stats.last_transfer_bytes = length;
	accel->stats.last_error = ret;

	if (!ret) {
		accel->stats.complete_count++;
		return;
	}

	accel->stats.error_count++;
	if (ret == -ETIMEDOUT)
		accel->stats.timeout_count++;
}

static int zybo_aes_ctr_run_transfer(struct zybo_aes_ctr_dev *accel,
				     const struct zybo_aes_ctr_transfer *transfer)
{
	struct dma_async_tx_descriptor *rx_desc;
	struct dma_async_tx_descriptor *tx_desc;
	dma_cookie_t rx_cookie;
	dma_cookie_t tx_cookie;
	enum dma_ctrl_flags desc_flags = DMA_CTRL_ACK | DMA_PREP_INTERRUPT;
	enum dma_status rx_status;
	enum dma_status tx_status;
	void __user *input_user = u64_to_user_ptr(transfer->input_ptr);
	void __user *output_user = u64_to_user_ptr(transfer->output_ptr);
	u32 timeout_ms = transfer->timeout_ms ?: ZYBO_AES_CTR_DMA_TIMEOUT_DEFAULT;
	unsigned long deadline;
	int ret;

	if (!accel->config_valid)
		return -EINVAL;

	if (copy_from_user(accel->tx_cpu_buf, input_user, transfer->length))
		return -EFAULT;

	memset(accel->rx_cpu_buf, 0, transfer->length);
	reinit_completion(&accel->tx_done);
	reinit_completion(&accel->rx_done);

	rx_desc = dmaengine_prep_slave_single(accel->rx_chan,
					      accel->rx_dma_addr,
					      transfer->length,
					      DMA_DEV_TO_MEM,
					      desc_flags);
	if (!rx_desc)
		return -EIO;

	rx_desc->callback = zybo_aes_ctr_dma_callback;
	rx_desc->callback_param = &accel->rx_done;
	rx_cookie = dmaengine_submit(rx_desc);
	ret = dma_submit_error(rx_cookie);
	if (ret)
		return ret;

	tx_desc = dmaengine_prep_slave_single(accel->tx_chan,
					      accel->tx_dma_addr,
					      transfer->length,
					      DMA_MEM_TO_DEV,
					      desc_flags);
	if (!tx_desc) {
		zybo_aes_ctr_terminate_dma(accel);
		return -EIO;
	}

	tx_desc->callback = zybo_aes_ctr_dma_callback;
	tx_desc->callback_param = &accel->tx_done;
	tx_cookie = dmaengine_submit(tx_desc);
	ret = dma_submit_error(tx_cookie);
	if (ret) {
		zybo_aes_ctr_terminate_dma(accel);
		return ret;
	}

	dma_async_issue_pending(accel->rx_chan);

	zybo_aes_ctr_program_config(accel);
	zybo_aes_ctr_start(accel);

	dma_async_issue_pending(accel->tx_chan);

	deadline = jiffies + msecs_to_jiffies(timeout_ms);

	ret = zybo_aes_ctr_wait_until(&accel->rx_done, deadline);
	if (ret) {
		zybo_aes_ctr_terminate_dma(accel);
		return ret;
	}

	ret = zybo_aes_ctr_wait_until(&accel->tx_done, deadline);
	if (ret) {
		zybo_aes_ctr_terminate_dma(accel);
		return ret;
	}

	rx_status = dma_async_is_tx_complete(accel->rx_chan, rx_cookie, NULL, NULL);
	tx_status = dma_async_is_tx_complete(accel->tx_chan, tx_cookie, NULL, NULL);
	if (rx_status != DMA_COMPLETE || tx_status != DMA_COMPLETE) {
		zybo_aes_ctr_terminate_dma(accel);
		return -EIO;
	}

	if (copy_to_user(output_user, accel->rx_cpu_buf, transfer->length))
		return -EFAULT;

	return 0;
}

static int zybo_aes_ctr_submit(struct zybo_aes_ctr_dev *accel,
			       const struct zybo_aes_ctr_transfer *transfer)
{
	int ret;

	ret = zybo_aes_ctr_validate_transfer(transfer);
	if (ret)
		return ret;

	mutex_lock(&accel->lock);
	accel->stats.submit_count++;
	ret = zybo_aes_ctr_run_transfer(accel, transfer);
	zybo_aes_ctr_note_transfer_result(accel, transfer->length, ret);
	mutex_unlock(&accel->lock);

	return ret;
}

static int zybo_aes_ctr_open(struct inode *inode, struct file *file)
{
	struct miscdevice *miscdev = file->private_data;
	struct zybo_aes_ctr_dev *accel;

	(void)inode;

	accel = container_of(miscdev, struct zybo_aes_ctr_dev, miscdev);
	file->private_data = accel;

	return 0;
}

static int zybo_aes_ctr_release(struct inode *inode, struct file *file)
{
	(void)inode;
	(void)file;
	return 0;
}

static long zybo_aes_ctr_ioctl(struct file *file, unsigned int cmd,
			       unsigned long arg)
{
	struct zybo_aes_ctr_dev *accel = file->private_data;
	void __user *argp = (void __user *)arg;
	struct zybo_aes_ctr_accel_info info;
	struct zybo_aes_ctr_dma_caps dma_caps;
	struct zybo_aes_ctr_config config;
	struct zybo_aes_ctr_transfer transfer;
	struct zybo_aes_ctr_status status;
	struct zybo_aes_ctr_stats stats;
	long ret = 0;

	if (_IOC_TYPE(cmd) != ZYBO_AES_CTR_ACCEL_IOCTL_MAGIC)
		return -ENOTTY;

	switch (cmd) {
	case ZYBO_AES_CTR_IOCTL_GET_INFO:
		zybo_aes_ctr_fill_info(accel, &info);
		if (copy_to_user(argp, &info, sizeof(info)))
			ret = -EFAULT;
		break;

	case ZYBO_AES_CTR_IOCTL_GET_DMA_CAPS:
		zybo_aes_ctr_fill_dma_caps(&dma_caps);
		if (copy_to_user(argp, &dma_caps, sizeof(dma_caps)))
			ret = -EFAULT;
		break;

	case ZYBO_AES_CTR_IOCTL_SET_CONFIG:
		if (copy_from_user(&config, argp, sizeof(config)))
			return -EFAULT;

		ret = zybo_aes_ctr_validate_config(&config);
		if (ret)
			return ret;

		mutex_lock(&accel->lock);
		accel->config = config;
		accel->config_valid = true;
		mutex_unlock(&accel->lock);
		break;

	case ZYBO_AES_CTR_IOCTL_GET_STATUS:
		mutex_lock(&accel->lock);
		zybo_aes_ctr_fill_status(accel, &status);
		mutex_unlock(&accel->lock);

		if (copy_to_user(argp, &status, sizeof(status)))
			ret = -EFAULT;
		break;

	case ZYBO_AES_CTR_IOCTL_SUBMIT:
		if (copy_from_user(&transfer, argp, sizeof(transfer)))
			return -EFAULT;

		ret = zybo_aes_ctr_submit(accel, &transfer);
		break;

	case ZYBO_AES_CTR_IOCTL_GET_STATS:
		mutex_lock(&accel->lock);
		stats = accel->stats;
		mutex_unlock(&accel->lock);

		if (copy_to_user(argp, &stats, sizeof(stats)))
			ret = -EFAULT;
		break;

	default:
		ret = -ENOTTY;
		break;
	}

	return ret;
}

#ifdef CONFIG_COMPAT
static long zybo_aes_ctr_compat_ioctl(struct file *file, unsigned int cmd,
				      unsigned long arg)
{
	return zybo_aes_ctr_ioctl(file, cmd, (unsigned long)compat_ptr(arg));
}
#endif

static const struct file_operations zybo_aes_ctr_fops = {
	.owner = THIS_MODULE,
	.open = zybo_aes_ctr_open,
	.release = zybo_aes_ctr_release,
	.unlocked_ioctl = zybo_aes_ctr_ioctl,
#ifdef CONFIG_COMPAT
	.compat_ioctl = zybo_aes_ctr_compat_ioctl,
#endif
};

static int zybo_aes_ctr_validate_mmio(struct platform_device *pdev,
				      struct zybo_aes_ctr_dev *accel)
{
	if (accel->regs_size < ZYBO_AES_CTR_MIN_MMIO_SIZE) {
		dev_err(&pdev->dev,
			"MMIO span %llu bytes is smaller than required minimum 0x%x bytes\n",
			(unsigned long long)accel->regs_size,
			ZYBO_AES_CTR_MIN_MMIO_SIZE);
		return -EINVAL;
	}

	return 0;
}

static void zybo_aes_ctr_release_dma(struct zybo_aes_ctr_dev *accel)
{
	if (accel->rx_chan)
		dmaengine_terminate_sync(accel->rx_chan);
	if (accel->tx_chan)
		dmaengine_terminate_sync(accel->tx_chan);

	if (accel->rx_cpu_buf)
		dma_free_coherent(accel->rx_dma_dev, accel->dma_buf_size,
				  accel->rx_cpu_buf, accel->rx_dma_addr);
	if (accel->tx_cpu_buf)
		dma_free_coherent(accel->tx_dma_dev, accel->dma_buf_size,
				  accel->tx_cpu_buf, accel->tx_dma_addr);

	if (accel->rx_chan)
		dma_release_channel(accel->rx_chan);
	if (accel->tx_chan)
		dma_release_channel(accel->tx_chan);

	accel->rx_cpu_buf = NULL;
	accel->tx_cpu_buf = NULL;
	accel->rx_chan = NULL;
	accel->tx_chan = NULL;
}

static int zybo_aes_ctr_init_dma(struct platform_device *pdev,
				 struct zybo_aes_ctr_dev *accel)
{
	int ret;

	accel->tx_chan = dma_request_chan(&pdev->dev, "tx");
	if (IS_ERR(accel->tx_chan)) {
		ret = PTR_ERR(accel->tx_chan);
		accel->tx_chan = NULL;
		return dev_err_probe(&pdev->dev, ret,
				     "failed to acquire DMA channel 'tx'\n");
	}

	accel->rx_chan = dma_request_chan(&pdev->dev, "rx");
	if (IS_ERR(accel->rx_chan)) {
		ret = PTR_ERR(accel->rx_chan);
		accel->rx_chan = NULL;
		zybo_aes_ctr_release_dma(accel);
		return dev_err_probe(&pdev->dev, ret,
				     "failed to acquire DMA channel 'rx'\n");
	}

	accel->tx_dma_dev = dmaengine_get_dma_device(accel->tx_chan);
	accel->rx_dma_dev = dmaengine_get_dma_device(accel->rx_chan);
	if (!accel->tx_dma_dev || !accel->rx_dma_dev) {
		zybo_aes_ctr_release_dma(accel);
		return dev_err_probe(&pdev->dev, -ENODEV,
				     "DMA channels do not expose mapping devices\n");
	}

	accel->dma_buf_size = ZYBO_AES_CTR_DMA_MAX_BYTES;

	accel->tx_cpu_buf = dma_alloc_coherent(accel->tx_dma_dev,
					       accel->dma_buf_size,
					       &accel->tx_dma_addr,
					       GFP_KERNEL);
	if (!accel->tx_cpu_buf) {
		zybo_aes_ctr_release_dma(accel);
		return dev_err_probe(&pdev->dev, -ENOMEM,
				     "failed to allocate coherent TX staging buffer\n");
	}

	accel->rx_cpu_buf = dma_alloc_coherent(accel->rx_dma_dev,
					       accel->dma_buf_size,
					       &accel->rx_dma_addr,
					       GFP_KERNEL);
	if (!accel->rx_cpu_buf) {
		zybo_aes_ctr_release_dma(accel);
		return dev_err_probe(&pdev->dev, -ENOMEM,
				     "failed to allocate coherent RX staging buffer\n");
	}

	init_completion(&accel->tx_done);
	init_completion(&accel->rx_done);
	memset(&accel->stats, 0, sizeof(accel->stats));

	dev_info(&pdev->dev,
		 "DMA channels ready: tx=MM2S, rx=S2MM, staging=%zu bytes per direction\n",
		 accel->dma_buf_size);

	return 0;
}

static int zybo_aes_ctr_probe(struct platform_device *pdev)
{
	struct zybo_aes_ctr_dev *accel;
	struct resource *res;
	int ret;

	accel = devm_kzalloc(&pdev->dev, sizeof(*accel), GFP_KERNEL);
	if (!accel)
		return -ENOMEM;

	accel->dev = &pdev->dev;
	mutex_init(&accel->lock);

	res = platform_get_resource(pdev, IORESOURCE_MEM, 0);
	if (!res)
		return dev_err_probe(&pdev->dev, -ENODEV,
				     "missing AXI-Lite MMIO resource\n");

	accel->regs_size = resource_size(res);
	accel->regs = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(accel->regs))
		return PTR_ERR(accel->regs);

	ret = zybo_aes_ctr_validate_mmio(pdev, accel);
	if (ret)
		return ret;

	accel->cached_version =
		zybo_aes_ctr_readl(accel, ZYBO_AES_CTR_REG_VERSION);
	if (accel->cached_version != ZYBO_AES_CTR_VERSION_V0_1)
		dev_warn(&pdev->dev,
			 "unexpected VERSION value 0x%08x; expected 0x%08x\n",
			 accel->cached_version, ZYBO_AES_CTR_VERSION_V0_1);

	ret = zybo_aes_ctr_init_dma(pdev, accel);
	if (ret)
		return ret;

	accel->miscdev.minor = MISC_DYNAMIC_MINOR;
	accel->miscdev.name = ZYBO_AES_CTR_ACCEL_DEVICE_NAME;
	accel->miscdev.fops = &zybo_aes_ctr_fops;
	accel->miscdev.parent = &pdev->dev;
	accel->miscdev.mode = 0600;

	ret = misc_register(&accel->miscdev);
	if (ret) {
		zybo_aes_ctr_release_dma(accel);
		return dev_err_probe(&pdev->dev, ret,
				     "failed to register /dev/%s\n",
				     ZYBO_AES_CTR_ACCEL_DEVICE_NAME);
	}

	platform_set_drvdata(pdev, accel);

	dev_info(&pdev->dev,
		 "/dev/%s ready: VERSION=0x%08x, MMIO span=%llu bytes\n",
		 ZYBO_AES_CTR_ACCEL_DEVICE_NAME, accel->cached_version,
		 (unsigned long long)accel->regs_size);

	return 0;
}

static void zybo_aes_ctr_remove(struct platform_device *pdev)
{
	struct zybo_aes_ctr_dev *accel = platform_get_drvdata(pdev);

	misc_deregister(&accel->miscdev);
	mutex_lock(&accel->lock);
	zybo_aes_ctr_release_dma(accel);
	mutex_unlock(&accel->lock);
	dev_info(&pdev->dev, "/dev/%s removed\n",
		 ZYBO_AES_CTR_ACCEL_DEVICE_NAME);
}

static const struct of_device_id zybo_aes_ctr_of_match[] = {
	{ .compatible = "xlnx,zybo-accel-ctrl-1.0" },
	{ }
};
MODULE_DEVICE_TABLE(of, zybo_aes_ctr_of_match);

static struct platform_driver zybo_aes_ctr_driver = {
	.probe = zybo_aes_ctr_probe,
	.remove = zybo_aes_ctr_remove,
	.driver = {
		.name = ZYBO_AES_CTR_DRIVER_NAME,
		.of_match_table = zybo_aes_ctr_of_match,
	},
};
module_platform_driver(zybo_aes_ctr_driver);

MODULE_AUTHOR("Shahin");
MODULE_DESCRIPTION("Zybo Z7 AES-CTR FPGA accelerator platform driver");
MODULE_LICENSE("GPL");