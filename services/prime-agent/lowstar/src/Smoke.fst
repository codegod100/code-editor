module Smoke
open FStar.HyperStack.ST
module B = LowStar.Buffer
module U8 = FStar.UInt8
module U32 = FStar.UInt32

/// XOR a byte buffer in place. Trivial code, but the point is the contract:
/// F* proves the buffer stays live, that we only touch `b`, and — crucially —
/// that every index is in bounds. No length argument can make this read wild.
val xor_bytes:
    b:B.buffer U8.t
  -> len:U32.t{B.length b == U32.v len}
  -> i:U32.t{U32.v i <= U32.v len}
  -> k:U8.t
  -> Stack unit
      (requires fun h -> B.live h b)
      (ensures fun h0 _ h1 -> B.live h1 b /\ B.modifies (B.loc_buffer b) h0 h1)
let rec xor_bytes b len i k =
  if U32.lt i len then begin
    B.upd b i (U8.logxor (B.index b i) k);
    xor_bytes b len (U32.add i 1ul) k
  end
