# RTL Design

## 1. Purpose and design boundary

The programmable-logic accelerator implements AES-128 in CTR mode behind 32-bit AXI-Stream input and output interfaces.

The RTL accepts a stream of payload data, assembles the stream into 128-bit logical blocks, generates an AES-CTR keystream from a 96-bit nonce and 32-bit counter, XORs the keystream with the payload, and serializes the transformed data back to the 32-bit stream interface.

The top-level RTL block is:

```text
aes_ctr_block_128
```

The accelerator receives:

- a 128-bit AES key,
- a 96-bit nonce,
- a 32-bit initial counter,
- a transaction-start signal,
- a 32-bit AXI-Stream input,
- downstream AXI-Stream ready,
- clock and active-low reset.

It produces:

- a 32-bit AXI-Stream output,
- AXI-Stream `TKEEP` and `TLAST`,
- an accelerator-idle indication.

The AES core itself remains a reusable block-encryption engine. CTR-mode behavior is implemented around it by the counter block, stream collector, controller, XOR datapath, and output serializer.

---

## 2. RTL hierarchy

The AES-CTR RTL hierarchy contains the following functional blocks.

### AES-CTR wrapper

```text
aes_ctr_block_128
├── aes_ctr_controller
├── aes_ctr_counter_block
├── aes_ctr_input_collector
├── aes_ctr_output_serializer
└── aes_encrypt_128
```

### Shared stream-control helpers

```text
aes_ctr_state_counter
aes_ctr_state_decoder
```

These helper blocks are used by both the input collector and output serializer to represent idle and the four possible 32-bit word positions within a 128-bit block.

### AES-128 core hierarchy

```text
aes_encrypt_128
├── aes_sub_bytes
│   └── aes_sbox
├── aes_shift_rows
├── aes_mix_columns
│   └── aes_mix_column
│       ├── aes_mul02
│       └── aes_mul03
├── aes_key_expand_round
│   ├── aes_rot_sub_word
│   │   └── aes_sbox
│   └── aes_rcon
```

The AES core is iterative rather than fully unrolled. One AES state and one round-key state are retained between rounds.

---

## 3. Top-level transaction flow

The complete RTL transaction is:

```text
                         aes_ctr_start
                              |
                  accepted only while idle
                              |
                              v
                    Load initial counter
                    q <- initial_counter_in
                              |
                              v
                    Start first CTR block
                              |
                 +------------+------------+
                 |                         |
                 v                         v
        Collect AXI-Stream input      Generate keystream
        up to four 32-bit words       AES-128(
                 |                    key_in,
                 |                    nonce_in || q)
                 |                         |
                 v                         v
          128-bit payload             128-bit keystream
                 |                         |
                 +------------+------------+
                              |
                              v
                 payload XOR keystream
                     (combinational)
                              |
                              v
                    Output serializer
                              |
                  emit 32-bit AXI-Stream
                  words with preserved
                     TKEEP / TLAST
                              |
                   +----------+----------+
                   |                     |
             TLAST was in          no TLAST in
             this input block      this 128-bit block
                   |                     |
                   v                     v
          Emit through the         Emit all four
          TLAST-marked word        output words
                   |                     |
                   v                     v
          Transaction complete     q <- q + 1
          aes_ctr_idle = 1                |
                                         v
                                Start next CTR block
                                         |
                                         +---- back to
                                              parallel
                                              collect + AES
```

Two aspects of this flow are especially important.

First, payload collection and AES keystream generation run concurrently for each CTR block. The AES engine does not require the payload because CTR mode encrypts the nonce/counter value rather than the payload itself.

Second, the payload/keystream XOR is not a separate clocked processing stage. At the top level it is a combinational relationship:

```text
ciphertext_block = keystream XOR block_out
```

The output serializer captures that result when the controller starts output serialization.

---

## 4. Clock and reset behavior

The design uses one clock:

```text
clk
```

State changes occur on rising clock edges.

The signal:

```text
reset_n
```

is active low, but the generated RTL implements it as a synchronous reset.

Stateful blocks use the form:

```text
rising clock edge
    if reset_n = 0
        reset registered state
    else
        perform normal update
```

The reset is therefore applied to the internal state on a rising clock edge; it is not implemented as an asynchronous reset input to the registers.

Reset clears the significant state of the accelerator, including:

- transaction-control state,
- block-control state,
- working counter,
- collector state and stored words,
- stored `TKEEP` information,
- stored `TLAST` position,
- serializer state,
- registered AES state,
- registered AES key state,
- AES round index,
- AES output,
- completion pulses.

After reset, the accelerator returns to its idle condition.

---

## 5. Input stream collection

### 5.1 Purpose

AES operates on 128-bit blocks, while the external streaming datapath is 32 bits wide.

`aes_ctr_input_collector` converts accepted 32-bit AXI-Stream transfers into a 128-bit payload block.

The collector also retains the `TKEEP` and `TLAST` information needed to reproduce the correct packet termination on the output stream.

### 5.2 Word acceptance

At the top-level wrapper:

```text
s_axis_tvalid
```

is connected to the collector's `word_valid` input, while the collector's ready output directly drives:

```text
s_axis_tready
```

Inside the collector, a word is consumed only when both are asserted:

```text
word_valid AND collector_ready_for_word
```

Therefore the effective accepted-input condition is the normal AXI-Stream handshake:

```text
s_axis_tvalid = 1
AND
s_axis_tready = 1
```

If `TVALID` is low, the collector does not advance.

If the collector is not ready, input data is not consumed.

### 5.3 Collector state

The collector uses the shared 3-bit state counter and decoder.

The meaningful states are:

| State | Meaning |
|---|---|
| `000` | idle |
| `001` | accepting first word |
| `010` | accepting second word |
| `011` | accepting third word |
| `100` | accepting fourth word |

When `start_collector` is accepted while the collector is idle, the collector clears the four internal word registers and their associated keep values, then moves into the first-word state.

The state advances only when a word is actually accepted.

This means gaps between input words are supported naturally: while no accepted handshake occurs, the collector keeps its current state and previously captured data unchanged.

### 5.4 Payload packing order

Accepted words are packed in the following order:

| Accepted stream word | Position in `block_out` |
|---|---|
| first | `[127:96]` |
| second | `[95:64]` |
| third | `[63:32]` |
| fourth | `[31:0]` |

For example:

```text
input word 1 = W0
input word 2 = W1
input word 3 = W2
input word 4 = W3
```

produces:

```text
block_out = W0 || W1 || W2 || W3
```

where `W0` occupies the most-significant 32 bits.

This ordering is also used for the four retained `TKEEP` values.

### 5.5 TKEEP preservation

Each accepted 32-bit input beat carries:

```text
s_axis_tkeep[3:0]
```

The collector stores one four-bit keep value for each accepted word.

For a complete four-word block, these are combined into:

```text
keep_block_out[15:0]
```

using the same ordering as the payload:

```text
first word TKEEP  -> bits [15:12]
second word TKEEP -> bits [11:8]
third word TKEEP  -> bits [7:4]
fourth word TKEEP -> bits [3:0]
```

The keep bits are metadata. They determine which byte lanes are meaningful when the output block is serialized.

The payload data itself is not byte-masked before the 128-bit XOR. Invalid lanes are instead identified by the corresponding output `TKEEP`.

### 5.6 Block completion and TLAST

Collection stops when either:

- four 32-bit words have been accepted, or
- an accepted word carries `s_axis_tlast = 1`.

`TLAST` is considered only together with an accepted input transfer. A raw `TLAST` value without a valid/ready handshake cannot terminate collection.

For a final block shorter than four words, the internal word registers were cleared when collection started, so the unused payload positions remain zero.

The collector also records which accepted word carried `TLAST`.

The position is retained as a one-hot four-bit mask aligned with the four stored word positions:

```text
word 1 -> 1000
word 2 -> 0100
word 3 -> 0010
word 4 -> 0001
```

This mask is internal metadata; it is later decoded by the serializer to recreate `TLAST` on the matching output word.

The serializer later uses this saved position to assert output `TLAST` on the corresponding output beat.

`collector_done` is a one-clock completion pulse.

The collected payload and metadata remain available after the collector returns to idle, allowing the controller to wait independently for AES completion.

---

## 6. CTR counter generation

The counter block is:

```text
aes_ctr_counter_block
```

It contains a registered 32-bit working counter:

```text
q
```

and continuously constructs the AES counter input as:

```text
counter_block_out = nonce_in || q
```

The resulting 128-bit AES input is therefore:

```text
127                                      32 31                0
+------------------------------------------+-------------------+
|              nonce_in[95:0]              |    counter q      |
+------------------------------------------+-------------------+
               96 bits                           32 bits
```

### 6.1 First block

At the beginning of an accepted AES-CTR transaction, the controller requests a counter update with initial-counter loading selected.

The working counter becomes:

```text
q <- initial_counter_in
```

The first AES keystream block therefore uses:

```text
nonce_in || initial_counter_in
```

### 6.2 Following blocks

After a non-final 128-bit payload block has been completely serialized, the controller begins another block.

For the new block:

```text
q <- q + 1
```

The counter advances exactly once per additional 128-bit CTR block, not once per 32-bit stream word.

All four words belonging to the same payload block therefore use the same counter value.

### 6.3 Counter rollover

Only the low 32 bits of the increment are stored.

The counter therefore wraps naturally:

```text
0xFFFFFFFF -> 0x00000000
```

### 6.4 New transactions

Every accepted new transaction explicitly reloads:

```text
initial_counter_in
```

The working counter does not continue from the preceding transaction.

---

## 7. AES-128 encryption engine

The AES encryption engine is:

```text
aes_encrypt_128
```

It is a reusable 128-bit block-encryption core.

For AES-CTR operation, its data input is not the payload.

It receives:

```text
aes_data_in = nonce_in || current_counter
```

and produces the 128-bit CTR keystream.

### 7.1 Iterative architecture

The AES core is iterative rather than fully unrolled.

Its significant registered state consists of:

- a 128-bit AES state register,
- a 128-bit key-state register,
- a 4-bit round index,
- a registered AES output,
- a registered one-cycle completion indication.

The round index also determines the external busy state.

Conceptually:

```text
round_index = 0  -> AES idle
round_index 1-10 -> AES busy
```

Only one AES block is being processed by this core at a time.

### 7.2 AES start

When `aes_start` is accepted while the AES engine is idle, the state register loads the AES initial AddRoundKey result:

```text
state <- aes_data_in XOR aes_key_in
```

The key-state register loads:

```text
key_state <- aes_key_in
```

and the round index advances from zero to round 1.

This establishes the AES state after the initial AddRoundKey before the normal round iterations begin.

### 7.3 Rounds 1 through 9

For rounds 1 through 9, the registered AES state passes through the combinational round datapath:

```text
registered state
       |
       v
    SubBytes
       |
       v
    ShiftRows
       |
       v
   MixColumns
       |
       v
  AddRoundKey
       |
       v
next registered state
```

The AddRoundKey operation is implemented as XOR with the newly generated round key.

One AES round is therefore advanced on each active clock iteration.

### 7.4 Final round

AES-128 round 10 does not contain MixColumns.

The final result is therefore formed as:

```text
SubBytes
   |
ShiftRows
   |
AddRoundKey
   |
AES output
```

The final result is captured in the registered `aes_data_out`.

At completion:

- the round index returns to zero,
- the AES busy indication falls,
- `aes_done` is asserted for one clock.

---

## 8. AES round-key generation

The round-key block is:

```text
aes_key_expand_round
```

It calculates the next AES-128 round key combinationally from the current 128-bit key state and current round index.

The input key is treated as four 32-bit words:

```text
W0 || W1 || W2 || W3
```

The next key is generated as:

```text
W0' = W0 XOR RotSubWord(W3) XOR Rcon
W1' = W0' XOR W1
W2' = W1' XOR W2
W3' = W2' XOR W3
```

and then reconstructed as:

```text
W0' || W1' || W2' || W3'
```

### 8.1 RotSubWord

`aes_rot_sub_word` applies the AES key-schedule transformation to the final 32-bit key word.

It performs:

```text
RotWord
   |
SubWord
```

The four SubWord byte substitutions are implemented with parallel S-box instances.

### 8.2 Rcon

`aes_rcon` selects the AES round constant from the round index.

The implemented values for rounds 1 through 10 are:

```text
01 02 04 08 10 20 40 80 1B 36
```

in the most-significant byte of the 32-bit Rcon word.

### 8.3 Parallelism with state transformation

Round-key generation is combinational and occurs while the current AES state is also passing through SubBytes, ShiftRows, and, for rounds 1 through 9, MixColumns.

Therefore a normal AES round conceptually performs:

```text
               current state
                    |
       SubBytes -> ShiftRows -> MixColumns
                    |               |
                    |               |
                    |          AddRoundKey
                    |               ^
                    |               |
               current key -> key expansion
```

The next state and next key are then registered together on the active clock edge.

This avoids running the complete key schedule as a separate preliminary phase.

---

## 9. AES primitive blocks

### 9.1 SubBytes

`aes_sub_bytes` applies the AES S-box to all 16 bytes of the 128-bit state.

The implementation instantiates 16 combinational `aes_sbox` blocks.

All 16 byte substitutions therefore occur in parallel within the round combinational datapath.

### 9.2 S-box

`aes_sbox` is implemented as a complete VHDL lookup table covering all 256 8-bit input values.

It has no internal clocked state.

### 9.3 ShiftRows

`aes_shift_rows` implements the AES ShiftRows transformation through fixed byte reordering.

No sequential state is required.

The byte mapping follows the AES state convention used throughout this RTL, where the first AES byte is located at the most-significant side of the 128-bit state.

### 9.4 MixColumns

`aes_mix_columns` divides the 128-bit AES state into four AES columns and instantiates four `aes_mix_column` blocks.

All four columns are transformed in parallel.

For one input column:

```text
a0
a1
a2
a3
```

the outputs implement the standard AES matrix:

```text
b0 = 02*a0 XOR 03*a1 XOR a2    XOR a3
b1 = a0    XOR 02*a1 XOR 03*a2 XOR a3
b2 = a0    XOR a1    XOR 02*a2 XOR 03*a3
b3 = 03*a0 XOR a1    XOR a2    XOR 02*a3
```

where multiplication occurs in the AES finite field.

### 9.5 Multiplication by 2

`aes_mul02` implements the AES `xtime` operation.

The byte is shifted left by one bit.

If the original most-significant bit is zero, the shifted result is used directly.

If the original most-significant bit is one, the shifted result is XORed with:

```text
0x1B
```

to perform reduction in the AES finite field.

### 9.6 Multiplication by 3

`aes_mul03` reuses `aes_mul02`:

```text
03*x = 02*x XOR x
```

Both `aes_mul02` and `aes_mul03` are combinational.

---

## 10. Payload and keystream combination

CTR mode does not pass the payload through the AES round function.

For each logical block:

```text
counter_block = nonce_in || q
keystream     = AES-128(key_in, counter_block)
```

The payload result is then:

```text
ciphertext_block = block_out XOR keystream
```

The same operation is used for encryption and decryption.

The XOR is implemented directly at the `aes_ctr_block_128` level and is combinational.

There is no separate XOR controller, state machine, busy indication, or completion cycle.

The serializer captures the XOR result only after both:

- payload collection has completed,
- AES keystream generation has completed.

---

## 11. Output serialization

The output serializer is:

```text
aes_ctr_output_serializer
```

It converts one completed 128-bit AES-CTR result into up to four 32-bit AXI-Stream transfers.

### 11.1 Serializer capture

When the controller starts the serializer while it is idle, the serializer registers:

- the 128-bit XOR result,
- the 16-bit stored keep mask,
- the stored TLAST-word position.

This creates a stable local copy of everything required for the output block.

### 11.2 Output ordering

The serializer transmits the 128-bit result in the same order used by the collector:

| Output transfer | Ciphertext bits |
|---|---|
| first | `[127:96]` |
| second | `[95:64]` |
| third | `[63:32]` |
| fourth | `[31:0]` |

The corresponding four-bit sections of the stored keep mask are emitted in the same order.

The 32-bit stream ordering is therefore preserved through the accelerator.

### 11.3 AXI-Stream valid/ready behavior

While the serializer is in one of its four word states:

```text
m_axis_tvalid = 1
```

The serializer advances only when the downstream interface accepts the current word:

```text
m_axis_tvalid = 1
AND
m_axis_tready = 1
```

Because state does not advance while `m_axis_tready = 0`, the currently selected:

- `m_axis_tdata`,
- `m_axis_tkeep`,
- `m_axis_tlast`,
- `m_axis_tvalid`

remain stable during backpressure.

No output word is skipped merely because the downstream interface temporarily deasserts `TREADY`.

### 11.4 TLAST reproduction

The collector records which accepted input word carried `TLAST`.

The serializer uses that stored position to assert:

```text
m_axis_tlast
```

on the corresponding output word.

For example:

```text
input TLAST on word 1 -> output TLAST on word 1
input TLAST on word 2 -> output TLAST on word 2
input TLAST on word 3 -> output TLAST on word 3
input TLAST on word 4 -> output TLAST on word 4
```

If the transaction ends after fewer than four input words, the serializer emits only through the TLAST-marked word.

It does not transmit the zero-filled unused collector positions.

---

## 12. Block completion versus transaction completion

The serializer provides two different completion indications:

```text
serializer_done
serializer_last_done
```

They serve different purposes.

### `serializer_done`

This indicates that output serialization for the current CTR block has finished.

For an intermediate block with no `TLAST`, that means all four output words have been accepted. The controller can then advance the CTR counter and begin another block.

For a final block, `serializer_done` may occur together with `serializer_last_done`; transaction termination is determined by `serializer_last_done`, not by `serializer_done` alone.

### `serializer_last_done`

This indicates that the output beat carrying the stored transaction `TLAST` has actually been accepted by the downstream AXI-Stream interface.

The underlying condition includes both:

```text
m_axis_tlast = 1
AND
m_axis_tready = 1
```

Therefore the accelerator does not declare the complete transaction finished merely because the final word is being presented.

It waits until that final output transfer is accepted.

This distinction allows the controller to differentiate:

```text
current 128-bit block complete
```

from:

```text
entire AXI-Stream transaction complete
```

---

## 13. AES-CTR controller

The coordination block is:

```text
aes_ctr_controller
```

The generated implementation does not use one conventional enumerated FSM.

Instead, it maintains several small registered control conditions representing:

- overall transaction active/idle,
- current CTR block active/idle,
- AES started/not started,
- collector started/not started,
- serializer started/not started,
- AES result ready/not ready,
- collected payload ready/not ready.

Combinational conditions around these registers generate the functional control signals:

```text
initialize_counter_block
produce_counter_block
start_collector
start_aes
start_serializer
aes_ctr_idle
```

For documentation purposes, the meaningful behavior is the transaction sequence rather than the generated intermediate gate names.

### 13.1 Transaction acceptance

A new external start is accepted only when:

```text
aes_ctr_idle = 1
```

The accepted start:

- marks the accelerator transaction active,
- loads the configured initial counter,
- creates the first block-processing event.

A start pulse received while the accelerator is already busy does not reinitialize the active transaction.

### 13.2 Per-block launch

For each CTR block, the controller independently starts:

- the input collector,
- the AES engine.

They then operate concurrently.

The collector fills the payload block from the 32-bit stream.

At the same time, the AES engine generates the keystream from:

```text
key_in
nonce_in || current_counter
```

### 13.3 Independent completion tracking

The collector and AES core are not required to finish on the same clock.

The controller remembers completion of each side separately.

Conceptually:

```text
collector_done -> payload ready
aes_done       -> keystream ready
```

Only when both results are ready does the controller start the output serializer.

This is important because the input stream can contain gaps while the AES core has its own fixed iterative processing sequence.

### 13.4 Following blocks

If serialization completes without completing the packet, the controller starts the next CTR block.

The counter is incremented once, and the collector and AES engine are launched again for the new block.

### 13.5 Final completion

If the serializer successfully transfers the output beat carrying `TLAST`, the controller terminates the complete transaction.

The overall busy state is cleared and:

```text
aes_ctr_idle = 1
```

is restored.

---

## 14. Parallel and sequential behavior

The design contains parallelism at several levels, but it is not a fully pipelined multi-block AES accelerator.

### 14.1 Operations performed in parallel

For one CTR block:

```text
input payload collection
```

runs concurrently with:

```text
AES-128 keystream generation
```

Inside each AES round:

```text
16 S-box substitutions
```

are performed in parallel.

The four MixColumns column transformations are also performed in parallel.

Round-key calculation occurs in parallel with the AES state transformation for the same round.

The final payload/keystream XOR is combinational.

### 14.2 Operations performed sequentially

The four 32-bit input words are accepted sequentially through the AXI-Stream interface.

AES rounds are iterative across successive clock cycles.

The four possible output words are serialized sequentially.

Different AES counter blocks are not simultaneously resident in independent AES pipeline stages.

The design therefore overlaps payload collection with AES processing for the same block, but does not implement a fully pipelined AES architecture capable of accepting a new independent 128-bit AES block every clock.

### 14.3 Block-level execution model

A useful representation is:

```text
Block N:

    +---------------- Payload collection ----------------+
    |                                                    |
    +---------------- AES keystream ---------------------+
                              |
                         both complete
                              |
                         serialization
                              |
                         block complete
                              |
                      begin Block N+1
```

The next block begins after the previous block has completed its output serialization.

---

## 15. Partial final blocks

The stream wrapper supports a final transaction block containing:

- one 32-bit word,
- two 32-bit words,
- three 32-bit words,
- four 32-bit words.

A partial final block is identified by an accepted input word carrying `TLAST` before all four collection positions have been filled.

The collector:

1. preserves every accepted payload word,
2. preserves each accepted word's `TKEEP`,
3. records the word position containing `TLAST`,
4. completes the current logical block,
5. leaves later unused word registers zero.

AES still generates a full 128-bit keystream block.

The full internal 128-bit payload is XORed with that keystream.

The serializer then outputs only the meaningful words through the saved TLAST position and reproduces the corresponding `TKEEP` values.

For a partially valid final 32-bit word, `TKEEP` identifies the valid byte lanes.

The current RTL does not define malformed-input rejection rules for arbitrary or invalid `TKEEP` patterns. `TKEEP` is preserved as supplied for accepted stream words.

---

## 16. Configuration behavior

The AES key and nonce enter the RTL as top-level configuration inputs:

```text
key_in
nonce_in
```

They are not copied into dedicated transaction-level configuration registers inside `aes_ctr_block_128`.

The AES core loads `key_in` when a block-level AES operation starts, and the counter block forms its AES input directly from:

```text
nonce_in || q
```

The integrated system therefore keeps key and nonce stable during an active transaction.

The working counter is different: it is explicitly stored internally.

At transaction start:

```text
q <- initial_counter_in
```

After every non-final block:

```text
q <- q + 1
```

A later transaction reloads the then-current configured initial-counter value.

Configuration values may therefore be changed between transactions, while the active transaction uses stable key and nonce inputs together with its internal working counter.

---

## 17. Stream ordering and AES byte ordering

The RTL preserves 32-bit stream-word ordering:

```text
first input word  -> bits [127:96] -> first output word
second input word -> bits [95:64]  -> second output word
third input word  -> bits [63:32]  -> third output word
fourth input word -> bits [31:0]   -> fourth output word
```

Within the AES core, the 128-bit state uses the project AES byte convention in which the first AES byte is located at the most-significant side of the state.

That byte convention is used consistently by the SubBytes, ShiftRows, MixColumns, key-expansion, Rcon, and RotWord/SubWord logic described above.

RTL regression evidence is documented with the [ModelSim regression suite](../tests/rtl/modelsim/README.md), while system-level validation and performance results are kept under [results/](../results/README.md).

---

## 18. Important implementation properties

The current RTL can be summarized by the following properties:

| Property | Implementation |
|---|---|
| External stream width | 32 bits |
| Internal AES/CTR block width | 128 bits |
| AES key size | 128 bits |
| Nonce size | 96 bits |
| Counter size | 32 bits |
| Counter block | `nonce[95:0] || counter[31:0]` |
| AES architecture | iterative |
| AES block concurrency | one AES block at a time |
| Input/AES overlap | yes, within the same CTR block |
| AES state/key expansion overlap | yes |
| SubBytes parallelism | 16 bytes in parallel |
| MixColumns parallelism | 4 columns in parallel |
| Payload/keystream XOR | combinational |
| Input backpressure | controlled by `s_axis_tready` |
| Output backpressure | supported |
| Partial final blocks | supported |
| `TKEEP` preservation | supported |
| `TLAST` preservation | supported |
| Busy start | ignored |
| Counter rollover | natural 32-bit wrap |
| Reset polarity | active low |
| Reset implementation | synchronous |

---

## 19. RTL design boundary

This RTL intentionally handles only the accelerator-side processing required for AES-CTR operation.

It is responsible for:

- AXI-Stream payload acceptance,
- 32-bit to 128-bit block assembly,
- valid-byte and final-word metadata preservation,
- CTR counter generation,
- AES-128 keystream generation,
- payload/keystream XOR,
- 128-bit to 32-bit output serialization,
- stream backpressure,
- block sequencing,
- transaction completion.

It is not responsible for:

- AXI DMA programming,
- DDR buffer management,
- AXI-Lite register implementation,
- Linux driver operation,
- user-space API handling,
- PetaLinux integration,
- software byte-array representation.

Those responsibilities belong to the surrounding system architecture described in [System Architecture](architecture.md).

This separation keeps `aes_ctr_block_128` focused on the streaming AES-CTR datapath and its required hardware control.
