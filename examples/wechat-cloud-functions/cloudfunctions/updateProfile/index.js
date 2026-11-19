const cloud = require('wx-server-sdk');
cloud.init({env: cloud.DYNAMIC_CURRENT_ENV});
const db = cloud.database();

exports.main = async event => {
  const {OPENID} = cloud.getWXContext();
  if (typeof event.displayName !== 'string' || !event.displayName.trim() || event.displayName.length > 80) {
    throw Error('invalid displayName');
  }
  await db.collection('users').doc(OPENID).set({data: {
    _openid: OPENID, open_id: OPENID, display_name: event.displayName.trim(),
  }});
  return (await cloud.callFunction({name: 'getUser'})).result;
};
