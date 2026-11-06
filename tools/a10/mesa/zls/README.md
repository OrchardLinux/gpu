# ZLS (depth/stencil store and reload) experiments

Run on the device, one result per test, waiting for the GPU to go idle after each, so a hang
does not affect the next test. Results are read from `dmesg` ("resetting the GPU").

- `depth-vk.c`, `color.*`: PR #6's `feature-rungs/depth/depth-vk.c` (MIT, Apple A9 port) with prints
  added: bytes the store wrote, a map of stored D32F values and of colour on a mismatch, where
  stencil 1 is stored, and two 128x128 cases. Build in the `orchard-gpu-alarm-build` image:
  `podman run --rm -v "$PWD:/zls" localhost/orchard-gpu-alarm-build sh /zls/depth-vk-build.sh`,
  then copy `depth-vk` to `/tmp` on the device.
- `dv.sh "ENV" CASE...`, `pv.sh CASE "ENV"...`, `am2.sh "ENV"...`: `depth-vk` per case or variant.
- `mx.sh CONFIG "ENV" TEST...`, `iso.sh "ENV"...`, `zs.sh TEST "ENV" ZOR...`, `good.sh`: dEQP tests per
  variant. `mx.sh` prints each render's ZLSCTL.

Run them with `orchard exec -- sh -s ARGS < script`. `ENV` switches came from temporary patches.
