//
//  BlurEffectRenderer.swift
//  Snapzy
//
//  Helper for rendering pixelated blur effect on image regions
//

import AppKit
import CoreGraphics
import CoreImage
import Metal

/// Quality tier for blur renders. Interactive work must be bounded so UI input never waits on expensive effects.
enum BlurRenderQuality: Equatable {
  case interactive
  case settled
  case export

  var maxGaussianSamplePixels: CGFloat? {
    switch self {
    case .interactive:
      return 420_000
    case .settled:
      return 1_600_000
    case .export:
      return nil
    }
  }
}

/// Renders pixelated blur effect for sensitive content redaction
struct BlurEffectRenderer {

  /// Default pixel block size for blur effect
  static let defaultPixelSize: CGFloat = 12

  /// Default Gaussian blur radius
  static let defaultGaussianRadius: Double = 20.0

  /// Security-first radius floor relative to smallest blur dimension
  private static let gaussianSecurityStrengthFactor: CGFloat = 0.35

  /// Sampling padding multiplier around target region
  private static let gaussianPaddingMultiplier: CGFloat = 2.0

  /// Hard cap to keep Gaussian cost bounded on very large regions
  private static let maxAdaptiveGaussianRadius: CGFloat = 120

  /// Shared GPU-backed CIContext for performance (reused across blur operations)
  static let sharedCIContext: CIContext = {
    if let metalDevice = MTLCreateSystemDefaultDevice() {
      return CIContext(mtlDevice: metalDevice, options: [
        .cacheIntermediates: true,
        .priorityRequestLow: false
      ])
    }
    return CIContext(options: [.cacheIntermediates: true])
  }()

  private struct RegionMapping {
    let imageScaleX: CGFloat
    let imageScaleY: CGFloat
    let clampedSourceRegion: CGRect
    let clampedDestRegion: CGRect
    let targetPixelRegion: CGRect
  }

  /// Draw a pixelated version of the source image region
  /// - Parameters:
  ///   - context: The graphics context to draw into
  ///   - sourceImage: The source image to sample from
  ///   - region: The region bounds in image coordinates
  ///   - pixelSize: Size of each pixel block (larger = more blur)
  static func drawPixelatedRegion(
    in context: CGContext,
    sourceImage: NSImage,
    region: CGRect,
    pixelSize: CGFloat = defaultPixelSize
  ) {
    drawPixelatedRegion(
      in: context,
      sourceImage: sourceImage,
      sourceRegion: region,
      destRegion: region,
      pixelSize: pixelSize
    )
  }

  /// Draw a pixelated region by sampling from source region and drawing into destination region.
  static func drawPixelatedRegion(
    in context: CGContext,
    sourceImage: NSImage,
    sourceRegion: CGRect,
    destRegion: CGRect,
    pixelSize: CGFloat = defaultPixelSize
  ) {
    guard let cgImage = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      drawFallbackBlur(in: context, region: destRegion)
      return
    }

    drawPixelatedRegion(
      in: context,
      sourceCGImage: cgImage,
      sourceSize: sourceImage.size,
      sourceRegion: sourceRegion,
      destRegion: destRegion,
      pixelSize: pixelSize
    )
  }

  /// Draw a pixelated region using a CGImage snapshot. Safe for background render work.
  static func drawPixelatedRegion(
    in context: CGContext,
    sourceCGImage cgImage: CGImage,
    sourceSize: CGSize,
    sourceRegion: CGRect,
    destRegion: CGRect,
    pixelSize: CGFloat = defaultPixelSize
  ) {
    guard sourceRegion.width > 0, sourceRegion.height > 0, destRegion.width > 0, destRegion.height > 0 else { return }

    guard let mapping = makeRegionMapping(
      sourceSize: sourceSize,
      cgImage: cgImage,
      sourceRegion: sourceRegion,
      destRegion: destRegion
    ) else {
      drawFallbackBlur(in: context, region: destRegion)
      return
    }

    guard let croppedImage = cgImage.cropping(to: mapping.targetPixelRegion) else {
      drawFallbackBlur(in: context, region: mapping.clampedDestRegion)
      return
    }

    drawPixelated(
      croppedImage: croppedImage,
      in: context,
      destRect: mapping.clampedDestRegion,
      pixelSize: pixelSize * max(mapping.imageScaleX, mapping.imageScaleY)
    )
  }

  /// Draw pixelated version of cropped image region.
  /// Uses downsample -> nearest-neighbor upscale instead of one fill call per block.
  private static func drawPixelated(
    croppedImage: CGImage,
    in context: CGContext,
    destRect: CGRect,
    pixelSize: CGFloat
  ) {
    let blockSize = max(1, pixelSize)
    let cols = max(1, Int(ceil(CGFloat(croppedImage.width) / blockSize)))
    let rows = max(1, Int(ceil(CGFloat(croppedImage.height) / blockSize)))

    guard let smallContext = CGContext(
      data: nil,
      width: cols,
      height: rows,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      drawFallbackBlur(in: context, region: destRect)
      return
    }

    smallContext.interpolationQuality = .low
    smallContext.draw(croppedImage, in: CGRect(x: 0, y: 0, width: cols, height: rows))

    guard let lowResolutionImage = smallContext.makeImage() else {
      drawFallbackBlur(in: context, region: destRect)
      return
    }

    context.saveGState()
    context.clip(to: destRect)
    context.setAllowsAntialiasing(false)
    context.setShouldAntialias(false)
    context.interpolationQuality = .none
    context.draw(lowResolutionImage, in: destRect)
    context.restoreGState()
  }

  /// Fallback blur when image sampling fails - draws semi-transparent overlay
  private static func drawFallbackBlur(in context: CGContext, region: CGRect) {
    context.setFillColor(NSColor.gray.withAlphaComponent(0.7).cgColor)
    context.fill(region)
  }


  /// Draw a subtle placeholder while an exact async blur render is pending.
  static func drawBlurPlaceholder(
    in context: CGContext,
    region: CGRect
  ) {
    context.saveGState()
    context.setFillColor(NSColor.gray.withAlphaComponent(0.32).cgColor)
    context.fill(region)
    context.restoreGState()
  }

  /// Draw blur preview during drag operation (simpler/faster)
  static func drawBlurPreview(
    in context: CGContext,
    region: CGRect,
    strokeColor: CGColor
  ) {
    // Draw semi-transparent overlay with pattern to indicate blur area
    context.setFillColor(NSColor.gray.withAlphaComponent(0.5).cgColor)
    context.fill(region)

    // Draw border
    context.setStrokeColor(strokeColor)
    context.setLineWidth(2)
    context.setLineDash(phase: 0, lengths: [6, 4])
    context.stroke(region)
    context.setLineDash(phase: 0, lengths: [])
  }

  /// Draw Gaussian blur region using CIFilter (GPU-accelerated).
  static func drawGaussianRegion(
    in context: CGContext,
    sourceImage: NSImage,
    region: CGRect,
    radius: Double = defaultGaussianRadius,
    quality: BlurRenderQuality = .export
  ) {
    drawGaussianRegion(
      in: context,
      sourceImage: sourceImage,
      sourceRegion: region,
      destRegion: region,
      radius: radius,
      quality: quality
    )
  }

  /// Draw Gaussian blur by sampling from source region and drawing into destination region.
  static func drawGaussianRegion(
    in context: CGContext,
    sourceImage: NSImage,
    sourceRegion: CGRect,
    destRegion: CGRect,
    radius: Double = defaultGaussianRadius,
    quality: BlurRenderQuality = .export
  ) {
    guard let cgImage = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      drawFallbackBlur(in: context, region: destRegion)
      return
    }

    drawGaussianRegion(
      in: context,
      sourceCGImage: cgImage,
      sourceSize: sourceImage.size,
      sourceRegion: sourceRegion,
      destRegion: destRegion,
      radius: radius,
      quality: quality
    )
  }

  /// Draw Gaussian blur using a CGImage snapshot. Safe for background render work.
  static func drawGaussianRegion(
    in context: CGContext,
    sourceCGImage cgImage: CGImage,
    sourceSize: CGSize,
    sourceRegion: CGRect,
    destRegion: CGRect,
    radius: Double = defaultGaussianRadius,
    quality: BlurRenderQuality = .export
  ) {
    guard sourceRegion.width > 0, sourceRegion.height > 0, destRegion.width > 0, destRegion.height > 0 else { return }

    guard let mapping = makeRegionMapping(
      sourceSize: sourceSize,
      cgImage: cgImage,
      sourceRegion: sourceRegion,
      destRegion: destRegion
    ) else {
      drawFallbackBlur(in: context, region: destRegion)
      return
    }

    let targetPixelRegion = mapping.targetPixelRegion
    let imageScale = max(mapping.imageScaleX, mapping.imageScaleY)
    let effectiveRadiusPx = effectiveGaussianRadiusPixels(
      baseRadius: CGFloat(radius),
      imageScale: imageScale,
      pixelRegion: targetPixelRegion
    )
    let samplePaddingPx = ceil(effectiveRadiusPx * gaussianPaddingMultiplier)
    let pixelBounds = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
    let sampledPixelRegion = targetPixelRegion.insetBy(dx: -samplePaddingPx, dy: -samplePaddingPx).intersection(pixelBounds)

    guard !sampledPixelRegion.isEmpty,
          let sampledCGImage = cgImage.cropping(to: sampledPixelRegion) else {
      drawFallbackBlur(in: context, region: mapping.clampedDestRegion)
      return
    }

    let sampleExtent = CGRect(x: 0, y: 0, width: sampledCGImage.width, height: sampledCGImage.height)
    let sampleArea = sampleExtent.width * sampleExtent.height
    let downsampleScale: CGFloat
    if let maxPixels = quality.maxGaussianSamplePixels, sampleArea > maxPixels {
      downsampleScale = max(0.05, sqrt(maxPixels / sampleArea))
    } else {
      downsampleScale = 1
    }

    let sampledCIImage = CIImage(cgImage: sampledCGImage)
    let workingImage: CIImage
    if downsampleScale < 0.999 {
      workingImage = sampledCIImage.transformed(by: CGAffineTransform(scaleX: downsampleScale, y: downsampleScale))
    } else {
      workingImage = sampledCIImage
    }

    let clampedInput = workingImage.clampedToExtent()
    let filter = CIFilter(name: "CIGaussianBlur")
    filter?.setValue(clampedInput, forKey: kCIInputImageKey)
    filter?.setValue(max(1, effectiveRadiusPx * downsampleScale), forKey: kCIInputRadiusKey)
    guard let outputImage = filter?.outputImage else {
      drawFallbackBlur(in: context, region: mapping.clampedDestRegion)
      return
    }

    let targetInSample = CGRect(
      x: targetPixelRegion.minX - sampledPixelRegion.minX,
      y: targetPixelRegion.minY - sampledPixelRegion.minY,
      width: targetPixelRegion.width,
      height: targetPixelRegion.height
    )
    let workingTarget = targetInSample.applying(CGAffineTransform(scaleX: downsampleScale, y: downsampleScale))
      .intersection(workingImage.extent)
    guard !workingTarget.isEmpty else {
      drawFallbackBlur(in: context, region: mapping.clampedDestRegion)
      return
    }

    let croppedTargetOutput = outputImage.cropped(to: workingTarget)
    guard let blurredCGImage = sharedCIContext.createCGImage(croppedTargetOutput, from: workingTarget) else {
      drawFallbackBlur(in: context, region: mapping.clampedDestRegion)
      return
    }

    context.saveGState()
    context.clip(to: mapping.clampedDestRegion)
    context.interpolationQuality = downsampleScale < 0.999 ? .high : .default
    context.draw(blurredCGImage, in: mapping.clampedDestRegion)
    context.restoreGState()
  }

  private static func makeRegionMapping(
    sourceSize: CGSize,
    cgImage: CGImage,
    sourceRegion: CGRect,
    destRegion: CGRect
  ) -> RegionMapping? {
    guard sourceSize.width > 0, sourceSize.height > 0 else { return nil }

    let normalizedSourceRegion = sourceRegion.standardized
    let normalizedDestRegion = destRegion.standardized
    guard normalizedSourceRegion.width > 0, normalizedSourceRegion.height > 0,
          normalizedDestRegion.width > 0, normalizedDestRegion.height > 0 else { return nil }

    let imageBounds = CGRect(origin: .zero, size: sourceSize)
    let clampedSourceRegion = normalizedSourceRegion.intersection(imageBounds)
    guard !clampedSourceRegion.isEmpty else { return nil }

    let clampedDestRegion: CGRect
    if clampedSourceRegion.equalTo(normalizedSourceRegion) {
      clampedDestRegion = normalizedDestRegion
    } else {
      let scaleX = normalizedDestRegion.width / normalizedSourceRegion.width
      let scaleY = normalizedDestRegion.height / normalizedSourceRegion.height
      let offsetX = clampedSourceRegion.minX - normalizedSourceRegion.minX
      let offsetY = clampedSourceRegion.minY - normalizedSourceRegion.minY
      clampedDestRegion = CGRect(
        x: normalizedDestRegion.minX + offsetX * scaleX,
        y: normalizedDestRegion.minY + offsetY * scaleY,
        width: clampedSourceRegion.width * scaleX,
        height: clampedSourceRegion.height * scaleY
      )
    }

    let imageScaleX = CGFloat(cgImage.width) / sourceSize.width
    let imageScaleY = CGFloat(cgImage.height) / sourceSize.height
    let pixelBounds = CGRect(x: 0, y: 0, width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))

    let pixelMinX = max(pixelBounds.minX, floor(clampedSourceRegion.minX * imageScaleX))
    let pixelMaxX = min(pixelBounds.maxX, ceil(clampedSourceRegion.maxX * imageScaleX))
    let pixelMinY = max(pixelBounds.minY, floor((sourceSize.height - clampedSourceRegion.maxY) * imageScaleY))
    let pixelMaxY = min(pixelBounds.maxY, ceil((sourceSize.height - clampedSourceRegion.minY) * imageScaleY))
    let targetPixelRegion = CGRect(
      x: pixelMinX,
      y: pixelMinY,
      width: pixelMaxX - pixelMinX,
      height: pixelMaxY - pixelMinY
    )

    guard !targetPixelRegion.isEmpty, targetPixelRegion.width >= 1, targetPixelRegion.height >= 1 else { return nil }

    return RegionMapping(
      imageScaleX: imageScaleX,
      imageScaleY: imageScaleY,
      clampedSourceRegion: clampedSourceRegion,
      clampedDestRegion: clampedDestRegion,
      targetPixelRegion: targetPixelRegion
    )
  }

  private static func effectiveGaussianRadiusPixels(
    baseRadius: CGFloat,
    imageScale: CGFloat,
    pixelRegion: CGRect
  ) -> CGFloat {
    let baseRadiusPx = max(1, baseRadius * imageScale)
    let minDimensionPx = min(pixelRegion.width, pixelRegion.height)
    let securityFloorPx = minDimensionPx * gaussianSecurityStrengthFactor
    let adaptiveRadiusPx = max(baseRadiusPx, securityFloorPx)
    let maxRegionRadiusPx = max(24, min(maxAdaptiveGaussianRadius, max(pixelRegion.width, pixelRegion.height) * 0.9))
    return min(adaptiveRadiusPx, maxRegionRadiusPx)
  }
}
