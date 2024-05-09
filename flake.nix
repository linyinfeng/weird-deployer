{
  outputs =
    { self }:
    {
      lib.weirdDeployer = import ./default.nix;
    };
}
