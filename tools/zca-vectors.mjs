// Sinh vectơ thử cho rz-zalo/src/crypto.rs: chép đúng thuật toán ParamsEncryptor / encodeAES / getSignKey của zca-js
// (src/utils.ts) nhưng dùng node:crypto thay crypto-js (AES-CBC, IV 0, PKCS#7 — cùng kết quả).   node tools/zca-vectors.mjs
import crypto from "node:crypto";
const md5 = (s) => crypto.createHash("md5").update(s).digest("hex");
const aes = (keyBytes, msg) => {
    const alg = { 16: "aes-128-cbc", 24: "aes-192-cbc", 32: "aes-256-cbc" }[keyBytes.length];
    const c = crypto.createCipheriv(alg, keyBytes, Buffer.alloc(16));
    return Buffer.concat([c.update(msg, "utf8"), c.final()]);
};
const processStr = (e) => { const r = [[], []]; [...e].forEach((ch, i) => r[i % 2].push(ch)); return { even: r[0], odd: r[1] }; };
const zcid = aes(Buffer.from("3FC4F0D2AB50057BCE0D90D9187A22B1", "utf8"), "30,imei-x,1700000000000").toString("hex").toUpperCase();
const n = md5("a1b2c3d4").toUpperCase();
const { even: ne } = processStr(n), { even: a, odd: s } = processStr(zcid);
const key = ne.slice(0, 8).join("") + a.slice(0, 12).join("") + s.reverse().slice(0, 12).join("");
const data = JSON.stringify({ computer_name: "Web", imei: "imei-x", language: "vi", ts: 1700000000000 });
const enc = aes(Buffer.from(key, "utf8"), data).toString("base64");
const getSignKey = (type, params) => { const k = Object.keys(params).sort(); let x = "zsecure" + type; for (const i of k) x += params[i]; return md5(x); };
const sign = getSignKey("getlogininfo", { zcid, zcid_ext: "a1b2c3d4", enc_ver: "v2", params: enc, type: 30, client_version: 695 });
const secret = Buffer.alloc(32, 7).toString("base64");
const api = aes(Buffer.from(secret, "base64"), '{"imei":"imei-x"}').toString("base64");
console.log(JSON.stringify({ zcid, key, enc, sign, api }, null, 1));
