// Existing-style CommonJS cloud function. Authentication never uses event.openid.
exports.main = async (event, context) => {
  const mysql = context.dbDriver === "mysql";
  const result = await context.db.query(
    "SELECT user_id, open_id, display_name FROM wcf_users WHERE user_id = " + (mysql ? "?" : "$1"),
    [context.userId],
  );
  if (result.rows.length !== 1) throw Error("user not found");
  return {user: result.rows[0], openid: context.OPENID, appid: context.APPID};
};
