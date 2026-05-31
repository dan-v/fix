let a = b + 1; b = 3; in a + b
let a = if true then 1 else b; b = a + 1; in b
let a = if false then b else 1; b = a + 1; in b
(rec { a = b + 1; b = 3; }).a
(rec { a = if true then 1 else b; b = a + 1; }).b
(rec { a.b = x + 1; x = 3; }).a.b
