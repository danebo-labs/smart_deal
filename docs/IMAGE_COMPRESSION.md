# Image Compression Implementation

## Problem
Images uploaded via the UI as base64 data were extremely large (often exceeding Amazon Bedrock Knowledge Base limits for Custom Data Sources).

## Solution
Implemented `ImageCompressionService` to automatically compress images before sending them to Bedrock.

## Features
- **Automatic compression**: Images are resized to max 1024x1024 and converted to JPEG (quality estimated from the size ratio, with a q=40 fallback if the first pass still exceeds the limit)
- **Smart skipping**: Images whose *decoded* binary is already ≤ `MAX_BINARY_BYTES` (3.75 MB) are not compressed
- **Size validation**: Ensures compressed images don't exceed Bedrock's 3.75 MB per-file limit
- **Thumbnail generation**: `compress_with_thumbnail` also produces an 88px-wide JPEG thumbnail in the same Vips load
- **Detailed logging**: Tracks compression ratios and sizes (`image_compression` structured event — see [METRICS.md](METRICS.md))
- **Error handling**: Graceful degradation with proper error messages; thumbnail failures fall back to compress-only (no thumbnail) so the upload still succeeds

## Limits
- **Custom Data Source**: Max 3.75 MB per file, decoded (`ImageCompressionService::MAX_BINARY_BYTES`)
- **Max dimensions**: 1024x1024 pixels (`MAX_DIMENSION`)
- **Format**: All compressed images converted to JPEG for consistency
- **Thumbnail**: 88px wide (2x DPR of the 44px mobile cell), JPEG q=70, typically ≤15 KB (`THUMB_MAX_WIDTH`, `THUMB_QUALITY`)

## Usage
The service is automatically invoked when uploading images through the RAG controller:

```ruby
# Images are automatically compressed
POST /rag/ask
{
  "question": "What's in this image?",
  "image": {
    "data": "base64_encoded_image_data",
    "media_type": "image/jpeg"
  }
}
```

## Field-photo thumbnail persistence

For the live field-photo diagnosis path, the 88px thumbnail produced by
`compress_with_thumbnail` — previously discarded once the diagnostic response
was delivered — is now persisted on the `field_photos` row
(`thumbnail_data`, `thumbnail_content_type`, `thumbnail_width`,
`thumbnail_height`) via `FieldPhotoStore.persist!`. It is what
`FieldPhoto#thumbnail_data_url` renders inline in the `photo_analyzed`
broadcast's `thumbnail_url`, so the chat chip shows a thumbnail without an
extra S3 round-trip. See [PRODUCT_ROADMAP.md](PRODUCT_ROADMAP.md#field-photo-contract)
for the retention window.

## Technical Details
- Uses `libvips` via the `image_processing` gem for fast, efficient compression
- Service Object pattern for clean separation of concerns
- Comprehensive test coverage in `test/services/image_compression_service_test.rb`

## Installation Requirements
Requires `libvips` system library:

```bash
# macOS
brew install vips

# Ubuntu/Debian
sudo apt-get install libvips-dev
```

## Performance
- Fast compression using SIMD-optimized libvips
- Typical compression: 80-95% size reduction for large images
- No compression overhead for already small images
