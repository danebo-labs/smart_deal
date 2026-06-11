# RAG benchmark retrieval evidence — 2026-06-10

**Mode:** `retrieval_preflight`  
**JSON SHA-256:** `118147398913a2646a4451b5315429d8cf6fcb032b7ae0c0899665c0ef28ec38`  
**Code fingerprint:** `6d90af032113cf2ff53ce4ddb9fbd510a01c34a0ef880e75670e8cc8af8c7954`  
**Vector configuration SHA-256:** `b6f28b74788058c93fff94f6b9a171797f5c247963e55da657acc0cff94f19ce`  
**Retrieval:** `HYBRID`, reranking off, `N=15`

Both exhaustive cases used the same resolved and applied scope:

- `s3://smart-deal-dev-kb/uploads/2026-06-09/danebo_fidelity_v2_22_paginas.pdf`
- `s3://smart-deal-dev-kb/uploads/2026-06-09/IMG_20260609_121243.jpg`

The functional evidence below came from the manual. Both cases recovered every
required chunk, with different ranks but identical chunk hashes.

| Unit | Block | Action | Expected result | Chunk SHA-256 | Rank isolated / conversation |
|---|---|---|---|---|---|
| ground-diagnostic-led | Ground controller | Prepare, select ground control, inspect diagnostic LEDs | Exact LED pattern is `REQUIRES_FIELD_VERIFICATION` against the manual image | `1eb881b866b0fa7e863911a356c7b3d0bedd7de9f61b0745a7555c5081b94c56` | 3 / 1 |
| ground-emergency-off | Ground controller | Push ground emergency stop to OFF | No function can execute | `1eb881b866b0fa7e863911a356c7b3d0bedd7de9f61b0745a7555c5081b94c56` | 3 / 1 |
| ground-key-platform-blocks-lift | Ground controller | Key at platform/OFF; hold lift | Platform does not rise | `1eb881b866b0fa7e863911a356c7b3d0bedd7de9f61b0745a7555c5081b94c56` | 3 / 1 |
| ground-key-ground-allows-lift | Ground controller | Key at ground; hold lift | Platform rises | `1eb881b866b0fa7e863911a356c7b3d0bedd7de9f61b0745a7555c5081b94c56` | 3 / 1 |
| ground-first-descent | Ground controller | Hold descent | Platform descends with alarm and stops at 2 m | `1eb881b866b0fa7e863911a356c7b3d0bedd7de9f61b0745a7555c5081b94c56` | 3 / 1 |
| ground-second-descent | Ground controller | Hold descent again | Platform reaches its lowest position with alarm | `1eb881b866b0fa7e863911a356c7b3d0bedd7de9f61b0745a7555c5081b94c56` | 3 / 1 |
| platform-emergency-off | Platform controller | Push platform emergency stop to OFF | No function executes | `e48384517d48440b0b47fa80930adf0be8afaed2f68185126f829f96888aba06` | 4 / 2 |
| platform-emergency-on-led | Platform controller | Pull platform emergency stop to ON | Diagnostic LED illuminates | `e48384517d48440b0b47fa80930adf0be8afaed2f68185126f829f96888aba06` | 4 / 2 |
| platform-horn | Platform controller | Press horn | Horn sounds | `e48384517d48440b0b47fa80930adf0be8afaed2f68185126f829f96888aba06` | 4 / 2 |
| platform-no-enable-blocks-motion | Platform controller | Move joystick without enable/start | No function executes | `e48384517d48440b0b47fa80930adf0be8afaed2f68185126f829f96888aba06` | 4 / 2 |
| platform-lift-and-pit-deploy | Platform controller | Select lift, hold enable, move blue/up | Platform rises and pit protection deploys | `e48384517d48440b0b47fa80930adf0be8afaed2f68185126f829f96888aba06` | 4 / 2 |
| platform-release-stops-lift | Platform controller | Release joystick | Platform stops rising | `e48384517d48440b0b47fa80930adf0be8afaed2f68185126f829f96888aba06` | 4 / 2 |
| platform-descent-alarm | Platform controller | Hold enable and move yellow/down | Platform descends and fall alarm sounds | `e48384517d48440b0b47fa80930adf0be8afaed2f68185126f829f96888aba06` | 4 / 2 |
| steering-left | Steering | Move thumb switch left | Wheel turns in indicated left direction | `218e41b740283140537f8ccb09847d63a3ae4bea1637e6a362eae641d95ff4ce` | 12 / 9 |
| steering-right | Steering | Move thumb switch right | Wheel turns in indicated right direction | `218e41b740283140537f8ccb09847d63a3ae4bea1637e6a362eae641d95ff4ce` | 12 / 9 |
| drive-brake-forward | Drive/brake | Hold enable, move up, return to center | Machine moves forward and stops | `cebc68373a8b310a353f43e1c0285efd7064cc30091d4c4bfd02a5ba32c19974` | 7 / 5 |
| drive-brake-reverse | Drive/brake | Hold enable, move down, return to center | Machine moves in reverse and stops | `cebc68373a8b310a353f43e1c0285efd7064cc30091d4c4bfd02a5ba32c19974` | 7 / 5 |
| limited-speed-setup-pit-deploy | Limited speed | Raise platform to about 2 m | Pit protection is deployed | `cebc68373a8b310a353f43e1c0285efd7064cc30091d4c4bfd02a5ba32c19974` | 7 / 5 |
| limited-speed-20cm | Limited speed | Select drive and move joystick with platform raised | Maximum speed does not exceed 20 cm/s | `cebc68373a8b310a353f43e1c0285efd7064cc30091d4c4bfd02a5ba32c19974` | 7 / 5 |
| tilt-sensor-stop-alarm | Tilt sensor | Put one side on 3.5 x 20 cm block and raise at least 2 m | Platform stops; alarm sounds 150 times/min | `218e41b740283140537f8ccb09847d63a3ae4bea1637e6a362eae641d95ff4ce` | 12 / 9 |
| pit-deploy-at-2m | Pit protection | Raise platform | Protection deploys at 2 m | `790fa2396256f9033885bf65af46c3bc3fcf7141851b3babe875a199fffba26b` | 10 / 10 |
| pit-pressure-immobility | Pit protection | Press and hold each side | Protection does not move | `790fa2396256f9033885bf65af46c3bc3fcf7141851b3babe875a199fffba26b` | 10 / 10 |
| pit-storage-return | Pit protection | Lower platform | Protection returns to storage position | `790fa2396256f9033885bf65af46c3bc3fcf7141851b3babe875a199fffba26b` | 10 / 10 |
| pit-obstacle-blocks-traction | Pit protection | Put 3.5 x 20 cm block below protection and raise | Alarm sounds and traction cannot execute at 2 m | `790fa2396256f9033885bf65af46c3bc3fcf7141851b3babe875a199fffba26b` | 10 / 10 |

Preparation-only steps are grouped into the action of their next independently
verifiable result. The incomplete LED illustration is not inferred; it remains
`REQUIRES_FIELD_VERIFICATION`.

**Coverage verdict:** complete for both `isolated:5` and `conversation:5`. The
generation and evaluator hardening may proceed without changing top-k, search
type, reranking, model, or temperature.
