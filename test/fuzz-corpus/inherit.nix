let x = 1; y = 2; in ({ inherit x y; }).y
let a = { inherit a; }; in a
({ inherit ({ x = 1; }) x; }).x
let src = { x = 7; y = 8; }; in ({ inherit (src) x y; }).x
let x = 1; in let inherit x; in x
let inherit ({ x = 2; }) x; in x
let or = 4; in ({ inherit or; }).or
({ inherit ({ or = 5; }) or; }).or
