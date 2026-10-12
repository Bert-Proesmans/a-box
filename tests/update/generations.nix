# Evaluated as node `machine` of a test next to an empty node `cache`, as in every scenario: the
# framework adds what the driver relies on (backdoor shell, /etc/hosts with the cache node).
{
  testers,
  sources,
  layout,
  machine,
  testDefaults,
}:
let
  node =
    (testers.runNixOSTest {
      name = "a-box-update-generations";
      defaults = testDefaults;
      # The main system's modules take them as module arguments.
      node.specialArgs = { inherit sources layout; };
      nodes = {
        inherit machine;
        cache = { };
      };
      testScript = "";
    }).nodes.machine;
in
{
  "1" = node.system.build.a-box-test-generation 1;
  "2" = node.system.build.a-box-test-generation 2;
}
