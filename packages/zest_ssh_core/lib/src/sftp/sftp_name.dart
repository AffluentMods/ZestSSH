// SPDX-License-Identifier: MIT
import 'package:zest_ssh_core/src/sftp/sftp_file_attrs.dart';
import 'package:zest_ssh_core/src/sftp/sftp_name_bytes.dart';
import 'package:zest_ssh_core/src/ssh_message.dart';

class SftpName {
  final String filename;

  final String longname;

  final SftpFileAttrs attr;

  SftpName({
    required this.filename,
    required this.longname,
    required this.attr,
  });

  factory SftpName.readFrom(SSHMessageReader reader) {
    // Its bytes as they are, where they are no UTF-8 (sftp_name_bytes.dart):
    // what is asked for with this name is the file the server listed. The
    // long name is only shown.
    final filename = reader.readSftpName();
    final longname = reader.readUtf8(allowMalformed: true);
    final attr = SftpFileAttrs.readFrom(reader);
    return SftpName(
      filename: filename,
      longname: longname,
      attr: attr,
    );
  }

  void writeTo(SSHMessageWriter writer) {
    writer.writeSftpName(filename);
    writer.writeUtf8(longname);
    attr.writeTo(writer);
  }

  @override
  String toString() {
    return 'SftpName(filename: $filename, longname: $longname, attr: $attr)';
  }
}
