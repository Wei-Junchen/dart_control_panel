/// Protocol-level errors produced by the NDJSON codec and daemon client.
///
/// These describe failures in the transport/framing layer, as opposed to
/// application errors returned `ok:false` from the daemon (which surface as
/// [OperationFailedException]).
class ProtocolException implements Exception {
  const ProtocolException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => cause == null
      ? 'ProtocolException: $message'
      : 'ProtocolException: $message ($cause)';
}

/// The request line could not be assembled (too long, bad type, ...).
class ProtocolCodecException extends ProtocolException {
  const ProtocolCodecException(super.message, {super.cause});
}

/// A line could not be parsed as a UTF-8 JSON object, or framing rules were
/// violated (empty line, oversized line, trailing data without newline).
class ProtocolDecodeException extends ProtocolException {
  const ProtocolDecodeException(super.message, {super.cause});
}

/// The daemon answered with `ok:false`. Carries the daemon-side state and
/// error string so the UI can refresh against real board values.
class OperationFailedException extends ProtocolException {
  const OperationFailedException(
    super.message, {
    required this.op,
    this.state,
    this.configRev,
  });

  final String op;
  final String? state;
  final int? configRev;
}

/// A response line carried an `id` different from the request id.
class ProtocolIdMismatch extends ProtocolException {
  const ProtocolIdMismatch(super.message, {super.cause});
}

/// No complete response arrived within the configured timeout.
class ProtocolTimeout extends ProtocolException {
  const ProtocolTimeout(super.message, {super.cause});
}

/// The socket failed, was closed, or the connection could not be established.
class ProtocolTransportClosed extends ProtocolException {
  const ProtocolTransportClosed(super.message, {super.cause});
}
