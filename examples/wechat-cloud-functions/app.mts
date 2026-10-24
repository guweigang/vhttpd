import getUser from "./functions/get-user.js";
import {createApplication, readConfig} from "./lib/application.mjs";

const config = readConfig(process.env);
export default createApplication({getUser: getUser.main}, config);
