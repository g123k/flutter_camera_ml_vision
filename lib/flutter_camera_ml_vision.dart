library flutter_camera_ml_vision;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:firebase_ml_vision/firebase_ml_vision.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

part 'utils.dart';

typedef HandleDetection<T> = Future<T> Function(FirebaseVisionImage image);
typedef Widget ErrorWidgetBuilder(BuildContext context, CameraError error);

enum CameraError {
  unknown,
  cantInitializeCamera,
  androidVersionNotSupported,
  noCameraAvailable,
}

enum _CameraState {
  loading,
  error,
  ready,
}

class CameraMlVision<T> extends StatefulWidget {
  final HandleDetection<T> detector;
  final Function(T) onResult;
  final WidgetBuilder loadingBuilder;
  final ErrorWidgetBuilder errorBuilder;
  final WidgetBuilder overlayBuilder;
  final CameraLensDirection cameraLensDirection;
  final ResolutionPreset resolution;
  final CameraController controller;

  CameraMlVision(
      {Key key,
      @required this.onResult,
      this.detector,
      this.loadingBuilder,
      this.errorBuilder,
      this.overlayBuilder,
      this.cameraLensDirection = CameraLensDirection.back,
      this.resolution,
      this.controller})
      : super(key: key);

  @override
  CameraMlVisionState createState() => CameraMlVisionState<T>();
}

class CameraMlVisionState<T> extends State<CameraMlVision<T>> {
  String _lastImage;
  CameraController _cameraController;
  HandleDetection _detector;
  ImageRotation _rotation;
  _CameraState _cameraMlVisionState = _CameraState.loading;
  CameraError _cameraError = CameraError.unknown;
  bool _alreadyCheckingImage = false;
  bool _isStreaming = false;
  bool _isDeactivate = false;

  @override
  void initState() {
    super.initState();

    final FirebaseVision mlVision = FirebaseVision.instance;
    _detector = widget.detector ?? mlVision.barcodeDetector().detectInImage;
    _initialize();
  }

  Future<void> stop() async {
    if (_cameraController != null) {
      if (_lastImage != null && File(_lastImage).existsSync()) {
        await File(_lastImage).delete();
      }

      Directory tempDir = await getTemporaryDirectory();
      _lastImage = '${tempDir.path}/${DateTime.now().millisecondsSinceEpoch}';
      try {
        await _cameraController.takePicture(_lastImage);
      } on PlatformException catch (e) {
        debugPrint('$e');
      }

      await _stop(false);
    }
  }

  Future<bool> hasFlash() {
    return _cameraController.hasTorch;
  }

  Future<void> turnFlashOn() {
    return _cameraController.torchOn();
  }

  Future<void> turnFlashOff() {
    return _cameraController.torchOff();
  }

  void _stop(bool silently) {
    Future.microtask(() async {
      if (_cameraController?.value?.isStreamingImages == true && mounted) {
        await _cameraController.stopImageStream();
      }
    });

    if (silently) {
      _isStreaming = false;
    } else {
      setState(() {
        _isStreaming = false;
      });
    }
  }

  void start() {
    if (_cameraController != null) {
      _start(false);
    }
  }

  void _start(bool silently) {
    _cameraController.startImageStream(_processImage);
    if (silently) {
      _isStreaming = true;
    } else {
      setState(() {
        _isStreaming = true;
      });
    }
  }

  CameraValue get cameraValue => _cameraController?.value;

  ImageRotation get imageRotation => _rotation;

  Future<void> Function() get prepareForVideoRecording =>
      _cameraController.prepareForVideoRecording;

  Future<void> startVideoRecording(String path) async {
    await _cameraController.stopImageStream();
    return _cameraController.startVideoRecording(path);
  }

  Future<void> stopVideoRecording() async {
    await _cameraController.stopVideoRecording();
    await _cameraController.startImageStream(_processImage);
  }

  Future<void> Function(String path) get takePicture =>
      _cameraController.takePicture;

  Future<void> _initialize() async {
    CameraDescription description =
        await _getCamera(widget.cameraLensDirection);
    if (description == null) {
      _cameraMlVisionState = _CameraState.error;
      _cameraError = CameraError.noCameraAvailable;

      return;
    }

    _cameraController = widget.controller ??
        CameraController(
          description,
          widget.resolution ?? ResolutionPreset.low,
          // As the doc says, better to set low when streaming images to avoid drop frames on older devices
          enableAudio: false,
        );

    if (!mounted) {
      return;
    }

    try {
      await _cameraController.initialize();
    } catch (ex, stack) {
      setState(() {
        _cameraMlVisionState = _CameraState.error;
        _cameraError = CameraError.cantInitializeCamera;
      });
      debugPrint('Can\'t initialize camera');
      debugPrint('$ex, $stack');
      return;
    }

    setState(() {
      _cameraMlVisionState = _CameraState.ready;
    });
    _rotation = _rotationIntToImageRotation(
      description.sensorOrientation,
    );

    await Future.delayed(Duration(
        milliseconds:
            200)); //hacky technique to avoid having black screen on some android devices
    start();
  }

  @override
  void deactivate() {
    final isCurrentRoute = ModalRoute.of(context).isCurrent;
    if (_cameraController != null) {
      if (_isDeactivate && isCurrentRoute) {
        _isDeactivate = false;
        _start(true);
      } else if (!_isDeactivate) {
        _isDeactivate = true;
        _stop(true);
      }
    }
    super.deactivate();
  }

  @override
  void dispose() {
    if (_lastImage != null && File(_lastImage).existsSync()) {
      File(_lastImage).delete();
    }

    if (_cameraController != null) {
      _cameraController.torchOff();
      _cameraController.dispose();
      _cameraController = null;
    }

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_cameraMlVisionState == _CameraState.loading) {
      return widget.loadingBuilder == null
          ? Center(child: CircularProgressIndicator())
          : widget.loadingBuilder(context);
    }
    if (_cameraMlVisionState == _CameraState.error) {
      return widget.errorBuilder == null
          ? Center(child: Text('$_cameraMlVisionState $_cameraError'))
          : widget.errorBuilder(context, _cameraError);
    }

    Widget cameraPreview = AspectRatio(
      aspectRatio: _cameraController.value.aspectRatio,
      child: _isStreaming
          ? CameraPreview(
              _cameraController,
            )
          : _getPicture(),
    );
    if (widget.overlayBuilder != null) {
      cameraPreview = Stack(
        fit: StackFit.passthrough,
        children: [
          cameraPreview,
          widget.overlayBuilder(context),
        ],
      );
    }
    return FittedBox(
      alignment: Alignment.center,
      fit: BoxFit.cover,
      child: SizedBox(
        width: _cameraController.value.previewSize.height *
            _cameraController.value.aspectRatio,
        height: _cameraController.value.previewSize.height,
        child: cameraPreview,
      ),
    );
  }

  _processImage(CameraImage cameraImage) async {
    if (!_alreadyCheckingImage) {
      _alreadyCheckingImage = true;
      try {
        final T results = await _detect<T>(cameraImage, _detector, _rotation);
        widget.onResult(results);
      } catch (ex, stack) {
        debugPrint('$ex, $stack');
      }
      _alreadyCheckingImage = false;
    }
  }

  void toggle() {
    if (_isStreaming && _cameraController.value.isStreamingImages) {
      stop();
    } else {
      start();
    }
  }

  Widget _getPicture() {
    if (_lastImage != null) {
      final file = File(_lastImage);
      if (file.existsSync()) {
        return Image.file(file);
      }
    }

    return Container();
  }
}
