'use strict';
// Synthetic sentinel is private fixture input; control output never includes it.
const sentinel = 'SYNTHETIC_PRIVATE_VALUE_6d3f1a';
const method = 'account/chatgptAuthTokens/refresh';
const last = `{"params":{"authToken":"${sentinel}","ignored":"split \\u0061 escape"},"method":"${method}","id":"owned-\\u0073tring-2"}\n`;
const prefix = [
  {method:'fixture/ready'},
  {method:'fixture/nested',params:{method,id:'nested-only',authToken:sentinel}},
].map(x => JSON.stringify(x)+'\n').join('') +
  `{"id":"duplicate-method","method":"${method}","method":"${method}"}\n`+
  `{"id":"duplicate-id","id":77,"method":"${method}"}\n`+
  JSON.stringify({id:900,result:{authToken:sentinel}})+'\n'+
  JSON.stringify({params:{authToken:sentinel,nested:{method,id:999}},id:101,method})+'\n';
const final = JSON.stringify({method:'fixture/continued',params:{count:2}})+'\n'+JSON.stringify({method:'fixture/done'})+'\n';
module.exports = {sentinel,method,last,prefix,initial:prefix+last,final,all:prefix+last+final};
