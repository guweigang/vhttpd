// Original SQL-only example; also supports MySQL. No wx-server-sdk facade.
import getUser from './functions/get-user.js';
import {createApplication, readConfig} from './lib/application.mjs';
export default createApplication({getUser: getUser.main}, readConfig(process.env));
