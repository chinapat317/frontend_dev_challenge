import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';

/// Standard network image with a shimmer placeholder.
class TheNetworkImage extends StatefulWidget {
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
  State<TheNetworkImage> createState() => _TheNetworkImageState();
}

/// Emitted after a successfully decoded image has rendered its first frame.
/// Placeholders and error widgets never emit this notification.
class NetworkImageLoadedNotification extends Notification {
  const NetworkImageLoadedNotification(this.url);

  final String url;
}

class _TheNetworkImageState extends State<TheNetworkImage> {
  bool _reportedLoaded = false;
  int _generation = 0;

  @override
  void didUpdateWidget(TheNetworkImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _reportedLoaded = false;
      _generation++;
    }
  }

  Widget _frameBuilder(BuildContext context, Widget child, int? frame,
      bool wasSynchronouslyLoaded) {
    if (frame != null && !_reportedLoaded) {
      _reportedLoaded = true;
      final generation = _generation;
      final url = widget.url;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && generation == _generation) {
          NetworkImageLoadedNotification(url).dispatch(this.context);
        }
      });
    }
    return child;
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: widget.borderRadius ?? BorderRadius.zero,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final displayWidth = widget.width != null && widget.width!.isFinite
              ? constraints.constrainWidth(widget.width!)
              : constraints.maxWidth;
          final pixelRatio = MediaQuery.devicePixelRatioOf(context);
          // Decode at the display's physical width, preserving aspect ratio.
          // Fall back to the original image when no finite width is available.
          final decodeWidth = displayWidth.isFinite && displayWidth > 0
              ? (displayWidth * pixelRatio).ceil()
              : null;

          return CachedNetworkImage(
            imageUrl: widget.url,
            width: widget.width,
            height: widget.height,
            fit: widget.fit,
            memCacheWidth: decodeWidth,
            imageBuilder: (context, provider) => Image(
              // The custom builder receives the original provider. Match the
              // outer cache key so it retains display-sized decoding (RES-105).
              image: ResizeImage.resizeIfNeeded(decodeWidth, null, provider),
              width: widget.width,
              height: widget.height,
              fit: widget.fit,
              frameBuilder: _frameBuilder,
            ),
            placeholder: (context, _) => Shimmer.fromColors(
              baseColor: Colors.grey.shade300,
              highlightColor: Colors.grey.shade100,
              child: Container(
                  width: widget.width,
                  height: widget.height,
                  color: Colors.white),
            ),
            errorWidget: (context, _, __) => Container(
              width: widget.width,
              height: widget.height,
              color: Colors.grey.shade200,
              child: const Icon(Icons.image_not_supported_outlined),
            ),
          );
        },
      ),
    );
  }
}
