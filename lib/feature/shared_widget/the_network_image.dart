import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';

/// Standard network image with a shimmer placeholder.
class TheNetworkImage extends StatelessWidget {
  final String url;
  final double? width;
  final double? height;
  final BoxFit fit;
  final BorderRadius? borderRadius;

  const TheNetworkImage({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.borderRadius,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: borderRadius ?? BorderRadius.zero,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final displayWidth = width != null && width!.isFinite
              ? constraints.constrainWidth(width!)
              : constraints.maxWidth;
          final pixelRatio = MediaQuery.devicePixelRatioOf(context);
          // Decode at the display's physical width, preserving aspect ratio.
          // Fall back to the original image when no finite width is available.
          final decodeWidth = displayWidth.isFinite && displayWidth > 0
              ? (displayWidth * pixelRatio).ceil()
              : null;

          return CachedNetworkImage(
            imageUrl: url,
            width: width,
            height: height,
            fit: fit,
            memCacheWidth: decodeWidth,
            placeholder: (context, _) => Shimmer.fromColors(
              baseColor: Colors.grey.shade300,
              highlightColor: Colors.grey.shade100,
              child: Container(width: width, height: height, color: Colors.white),
            ),
            errorWidget: (context, _, __) => Container(
              width: width,
              height: height,
              color: Colors.grey.shade200,
              child: const Icon(Icons.image_not_supported_outlined),
            ),
          );
        },
      ),
    );
  }
}
