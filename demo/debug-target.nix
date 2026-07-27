let
  makePayload = answer: {
    inherit answer;
    items = [1 2 3];
  };
  payload = makePayload (21 * 2);
in {
  inherit payload;
}
