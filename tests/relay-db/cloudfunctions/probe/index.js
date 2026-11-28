const cloud = require('wx-server-sdk');
cloud.init({env: cloud.DYNAMIC_CURRENT_ENV});
const db = cloud.database();
exports.main = async event => {
  const doc = db.collection('relay_probe').doc(event.id || 'probe');
  if (event.action === 'write') {
    await doc.set({data: {value: event.value}});
    return (await doc.get()).data;
  }
  if (['transaction', 'rollback', 'hold'].includes(event.action)) {
    await db.runTransaction(async tx => {
      await tx.collection('relay_probe').doc(event.id).set({data: {value: event.value}});
      if (event.action === 'rollback') throw new Error('fixture rollback');
      if (event.action === 'hold') await new Promise(resolve => setTimeout(resolve, 1500));
      await tx.collection('relay_probe').doc(event.id + '-second').set({data: {value: event.value}});
    });
    return {committed: true};
  }
  try { return {found: true, data: (await doc.get()).data}; }
  catch (error) { if (error.code === 'DOCUMENT_NOT_FOUND') return {found: false}; throw error; }
};
