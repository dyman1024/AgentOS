import JavaScriptCore
import Foundation
let ctx = JSContext()!
ctx.exceptionHandler = { _, e in print("JS exception:", e?.toString() ?? "") }
let t0 = Date()
let v = ctx.evaluateScript("function fib(n){return n<2?n:fib(n-1)+fib(n-2)}; let s=0; for(let i=0;i<3e7;i++){s=(s+i*7)%1000003}; fib(30)+s")!
print("result", v.toInt32(), "ms", Int(Date().timeIntervalSince(t0)*1000))
