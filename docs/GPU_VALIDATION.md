# Cloud GPU validation

The current native candidate compiles and passes core and native unit tests. Its ordinary home renderer then loses the simulator's Metal service, including in an isolated diagnostic with app image readback disabled. This does not establish a defective skeleton, an unsupported GPU, or a resolved production bug. The next useful comparison runs the same application, Xcode 27.2, SDK-matched simulator, touch assertions and genuine render evidence on a runner with an explicit GPU allocation.

## Prepared runner selection

Both existing workflows accept `runner_class=standard` (default) or `runner_class=gpu`. The GPU selection uses GitHub's documented `xcode-27-xlarge` label. Pull-request runs remain on the standard runner; GPU selection is available through an explicit manual dispatch. The protected TestFlight workflow keeps its exact main SHA, validation dependency, environment review, signing checks and one-use upload intent.

```sh
gh workflow run unsigned-ios.yml -R timelabs-npo/blueshoes-roomwave \
  --ref release/twitter-surfer -f runtime_version=sdk-matched -f runner_class=gpu
```

Run this only after the owner confirms access and a spending budget. An enabled label is not evidence that GPU rendering succeeds. Each run records the actual Metal device name and selected capability flags without serial numbers or persistent hardware identifiers. Normal native input, image evidence and archive checks must still pass.

## Access and published price

GitHub lists the arm64 XLarge runner with 5 CPU cores, 8 GPU cores of hardware acceleration, and 14 GB RAM. It is a VM, not a bare-metal guarantee. Larger runners require GitHub Team or Enterprise Cloud, billing/spending access and repository access. They are billed for public repositories too.

The published macOS XLarge price checked on 26 November 2026 is **$0.102 per minute**, excluding the organization subscription. The existing unsigned and release-validation jobs each have a 65-minute workflow limit; the signing job has a 45-minute limit. One complete comparison plus those two release jobs therefore has a theoretical maximum of 175 runner minutes, **$17.85**, before any additional runs. Actual runtime can be lower. This is a cost estimate, not authorization to upgrade an organization or incur charges.

After a successful GPU comparison, independently inspect the retained actual course/rider images and input trace. Promote only the reviewed source, then dispatch the protected main release with `runner_class=gpu`. Record the actual allocated run/build before approving its existing environment. Preserve and reconcile upload/processing receipts; never rerun an upload to poll Apple.

The separate metadata-only diagnostic is not a release pass, and experimental compositor helpers have not been integrated into the release gate.

Sources: [runner specifications and access](https://docs.github.com/en/actions/reference/runners/larger-runners), [runner prices](https://docs.github.com/en/billing/reference/actions-runner-pricing).
