# Image Compression Implementation

## Problem
Images uploaded via the UI as base64 data were extremely large (often exceeding Amazon Bedrock Knowledge Base limits of 10MB for Custom Data Sources).

## Solution
Implemented `ImageCompressionService` to automatically compress images before sending them to Bedrock.

## Features
- **Automatic compression**: Images are resized to max 1024x1024 and converted to JPEG with 80% quality
- **Smart skipping**: Images smaller than 500KB are not compressed
- **Size validation**: Ensures compressed images don't exceed Bedrock's 10MB limit
- **Detailed logging**: Tracks compression ratios and sizes
- **Error handling**: Graceful degradation with proper error messages

## Limits
- **Custom Data Source**: Max 10MB (base64 encoded)
- **Target size**: 1-5MB for optimal performance
- **Max dimensions**: 1024x1024 pixels
- **Format**: All images converted to JPEG for consistency

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
