const cloud = require('wx-server-sdk');
cloud.init({env: cloud.DYNAMIC_CURRENT_ENV});
const db = cloud.database({throwOnNotFound: false});

exports.main = async () => {
  const {OPENID, APPID} = cloud.getWXContext();
  const {data} = await db.collection('users').doc(OPENID).get();
  // Reading a missing profile has no write side effect. updateProfile creates it.
  const user = data || {_id: OPENID, _openid: OPENID, open_id: OPENID, display_name: 'New user'};
  return {user, openid: OPENID, appid: APPID};
};
