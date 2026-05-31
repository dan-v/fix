{ a = 1; b = 2; }
({ a = 1; b = 2; }).a
({ a.b = 1; }).a.b or 2
({ a = {}; }).a.b or 2
({ a.b = 1; } ? a.b)
({ a = {}; } ? a.b)
{ a = 1; } // { a = 2; b = 3; }
rec { a = b + 1; b = 3; }
let x = 1; in { inherit x; }
