# Speculation pathology probe (see docs/parallel-redesign-plan.md).
#
# A lazy outer list whose elements are individually expensive AND whose
# producing lambda is "substantial" (>= SPECULATION_MIN_CODE_BYTES of
# bytecode, via the padding let-chain below) so speculation fires on it —
# but only ONE element is ever demanded. Serial eval forces one element;
# unbounded speculation would force all 256.
#
# This is the self-inflicted worst case: speculation guessing a large,
# never-demanded body. It exists to keep that case bounded. Measure with:
#   fix --file test/spec_pathology.nix --workers=1
#   fix --file test/spec_pathology.nix --workers=32
#   fix --file test/spec_pathology.nix --workers=32 --no-spec-thunks
# w=32-spec should stay within a small factor of w=1, not blow up.
let
  xs = builtins.genList (i:
    let
      e = builtins.foldl' (a: b: a + b) 0 (builtins.genList (x: x) 300000);
      p0 = i + 1; p1 = p0 + 1; p2 = p1 + 1; p3 = p2 + 1; p4 = p3 + 1; p5 = p4 + 1; p6 = p5 + 1; p7 = p6 + 1; p8 = p7 + 1; p9 = p8 + 1; p10 = p9 + 1; p11 = p10 + 1; p12 = p11 + 1; p13 = p12 + 1; p14 = p13 + 1; p15 = p14 + 1; p16 = p15 + 1; p17 = p16 + 1; p18 = p17 + 1; p19 = p18 + 1; p20 = p19 + 1; p21 = p20 + 1; p22 = p21 + 1; p23 = p22 + 1; p24 = p23 + 1; p25 = p24 + 1; p26 = p25 + 1; p27 = p26 + 1; p28 = p27 + 1; p29 = p28 + 1; p30 = p29 + 1; p31 = p30 + 1; p32 = p31 + 1; p33 = p32 + 1; p34 = p33 + 1; p35 = p34 + 1; p36 = p35 + 1; p37 = p36 + 1; p38 = p37 + 1; p39 = p38 + 1; p40 = p39 + 1; p41 = p40 + 1; p42 = p41 + 1; p43 = p42 + 1; p44 = p43 + 1; p45 = p44 + 1; p46 = p45 + 1; p47 = p46 + 1; p48 = p47 + 1; p49 = p48 + 1; p50 = p49 + 1; p51 = p50 + 1; p52 = p51 + 1; p53 = p52 + 1; p54 = p53 + 1; p55 = p54 + 1; p56 = p55 + 1; p57 = p56 + 1; p58 = p57 + 1; p59 = p58 + 1; p60 = p59 + 1;
    in e + p60
  ) 256;
in builtins.elemAt xs 0
