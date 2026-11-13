const cloud = require('wx-server-sdk');

exports.main = async () => {
  cloud.init({env: cloud.DYNAMIC_CURRENT_ENV});
  const context = cloud.getWXContext();
  return {message: 'wechat-cloud-ok', environment: context.ENV};
};
