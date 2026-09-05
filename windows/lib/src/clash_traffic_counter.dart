class ClashTrafficDelta {
  const ClashTrafficDelta({required this.upload, required this.download});

  final int upload;
  final int download;

  bool get hasTraffic => upload > 0 || download > 0;
}

class ClashTrafficCounter {
  int? _uploadTotal;
  int? _downloadTotal;

  ClashTrafficDelta? sample(Map<String, dynamic> json) {
    final upload = _intValue(json['uploadTotal']);
    final download = _intValue(json['downloadTotal']);
    if (upload == null || download == null) return null;

    final previousUpload = _uploadTotal;
    final previousDownload = _downloadTotal;
    _uploadTotal = upload;
    _downloadTotal = download;

    final uploadDelta = previousUpload != null && upload >= previousUpload
        ? upload - previousUpload
        : 0;
    final downloadDelta =
        previousDownload != null && download >= previousDownload
        ? download - previousDownload
        : 0;
    return ClashTrafficDelta(upload: uploadDelta, download: downloadDelta);
  }

  void reset() {
    _uploadTotal = null;
    _downloadTotal = null;
  }

  int? _intValue(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }
}
