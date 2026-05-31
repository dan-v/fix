"a${"b"}c"
let x = "b"; in "a${x}c"
"ab" + "cd"
let a = "ab"; in a + "cd"
({ foo = 42; })."foo"
({ a."b" = 3; }).a.b
