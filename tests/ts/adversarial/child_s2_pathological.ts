import { WireDecodeError } from "../../../src/ts/graph/load_error";
import {
  decodeLengthPrefixedString,
  decodeMatrix,
  decodeSeriesLayout,
  decodeWasmRecord,
} from "../../../src/ts/wire_decode";

const memory = new WebAssembly.Memory({ initial: 1 });
const dv = new DataView(memory.buffer);
dv.setUint32(0, 0xffffffff, true);
dv.setInt32(64, 0x7fffffff, true);
dv.setInt32(68, 0x7fffffff, true);
for (const fn of [
  () => decodeLengthPrefixedString(memory, 0),
  () => decodeMatrix(memory, 64),
  () => decodeSeriesLayout(memory, 0),
  () => decodeWasmRecord(memory, 64),
]) {
  try {
    fn();
  } catch (e) {
    if (!(e instanceof WireDecodeError)) {
      console.error(e);
      process.exit(2);
    }
  }
}
console.log("ok");
