import PostalMime from 'postal-mime';
globalThis.agentosParseMail=async raw=>{
 const mail=await PostalMime.parse(raw,{attachmentEncoding:'base64',maxNestingDepth:30,maxHeadersSize:100000,maxPartCount:100,maxRfc822NestingDepth:5,maxForwardedAddresses:100});
 return {messageId:mail.messageId||'',subject:mail.subject||'',from:mail.from||null,to:mail.to||[],cc:mail.cc||[],date:mail.date||'',text:mail.text||'',html:mail.html||'',attachments:(mail.attachments||[]).slice(0,30).map(a=>({filename:a.filename,mimeType:a.mimeType,disposition:a.disposition,contentId:a.contentId,base64:a.content}))};
};
