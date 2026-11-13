import './unit.test.mjs';
import './miniprogram.test.mjs';
import './cloud.test.mjs';
import './crypto.test.mjs';
import './storage.test.mjs';
import './storage-client.test.mjs';
import {run} from './support.mjs';
if (process.release?.name !== 'vjsx') throw new Error('Run this suite with vjsx');
await run();
