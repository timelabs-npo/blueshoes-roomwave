# Optional depth-model resource review

Current v0.3 photo creation analyzes actual pixels on-device using ImageIO, Vision attention saliency, contrast and edges. `InspiredCourseFactory` converts bounded coarse features into variations of authored terrain. It does not perform learned depth estimation or claim a measured 3D reconstruction.

A concrete next model candidate is [Apple's Core ML Depth Anything V2 Small](https://huggingface.co/apple/coreml-depth-anything-v2-small), distributed on Hugging Face. Its model card offers an approximately 49.8 MB Float16 variant, an Apache-2.0 license and Swift examples. This removes a custom conversion step from an initial evaluation, but does not establish this game's device latency, memory use or photo quality.

The [upstream Depth Anything V2 project](https://github.com/DepthAnything/Depth-Anything-V2) distinguishes the Small model's Apache-2.0 license from the noncommercial licenses of larger variants. Do not substitute another model on the assumption that all sizes share the same terms.

No model weights have been downloaded, bundled or executed for this rebuild. A useful evaluation would compare photo-derived course geometry with the current baseline on diverse, consented test pictures, measuring inference latency/peak memory on the target phone and checking whether the resulting courses are more interesting and still reachable. Relative depth remains a creative input to the same course validator. It must not bypass authored encounter constraints or silently upload the user's picture.
