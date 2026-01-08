import {
  readGraphManifestFromBytes,
  GraphManifestError,
} from "../../../src/ts/graph";

const junk = new Uint8Array(10_000);
for (let i = 0; i < junk.length; i++) junk[i] = (i * 17) & 0xff;
// plant magic sometimes
junk[0] = 0x00;
junk[1] = 0x61;
junk[2] = 0x73;
junk[3] = 0x6d;
try {
  readGraphManifestFromBytes(junk);
} catch (e) {
  if (!(e instanceof GraphManifestError)) {
    console.error(e);
    process.exit(2);
  }
}
console.log("ok");
