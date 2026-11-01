const cloud = require('wx-server-sdk');
cloud.init({env: cloud.DYNAMIC_CURRENT_ENV});
const db = cloud.database({throwOnNotFound: false});
const _ = db.command;
exports.main = async event => {
  const {OPENID} = cloud.getWXContext();
  const collection = db.collection('contract');
  const doc = collection.doc(OPENID);
  if (event.action === 'seed') {
    await doc.set({data: {_openid: OPENID, visits: 0, nested: {count: 1}, list: [1, 2], active: true}});
    return (await doc.get()).data;
  }
  if (event.action === 'inc') {
    return doc.update({data: {visits: _.inc(1), 'nested.count': _.inc(2), 'nested.other': 'value'}});
  }
  if (event.action === 'read') return (await doc.get()).data;
  if (event.action === 'operators') {
    await doc.update({data: {'nested.other': _.remove(), 'missing.value': _.remove(), 'nested.label': _.set('safe')}});
    return {
      doc: (await doc.get()).data,
      either: (await collection.where(_.or([{_openid: 'alice'}, {_openid: 'bob'}])).count()).total,
      member: (await collection.where({_openid: _.in([OPENID])}).count()).total,
      excluded: (await collection.where({visits: _.nin([8])}).count()).total,
      unequal: (await collection.where({_openid: _.neq(OPENID)}).count()).total,
      array: (await collection.where({list: [1, 2]}).count()).total,
      mixedType: (await collection.where({_openid: _.gt(1)}).count()).total,
    };
  }
  if (event.action === 'query') {
    const selected = collection.where(_.and([{_openid: OPENID}, {visits: _.gte(0).and(_.lt(100))}]));
    return {data: (await selected.orderBy('visits', 'desc').skip(0).limit(10).get()).data,
      count: await selected.count(), missing: (await collection.where({missing: _.exists(false)}).count()).total};
  }
  if (event.action === 'add') return collection.add({data: {_openid: OPENID, value: event.value}});
  if (event.action === 'remove') return collection.where({_openid: OPENID}).remove();
  if (event.action === 'tx') return db.runTransaction(async tx => {
    const before = (await tx.collection('contract').doc(OPENID).get()).data;
    await tx.collection('contract').doc(OPENID).update({data: {visits: _.inc(10)}});
    if (event.fail) throw Error('PRIVATE_ERROR_MUST_NOT_LEAK');
    return before.visits;
  });
  if (event.action === 'ordinaryFailure') { await doc.update({data: {visits: _.inc(1)}}); throw Error('PRIVATE_ERROR_MUST_NOT_LEAK'); }
  if (event.action === 'injection') return collection.where({value: event.value}).get();
  if (event.action === 'missing') return cloud.callFunction({name: 'notRegistered'});
  if (event.action === 'storage') return cloud.uploadFile({});
  throw Error('unknown action');
};
