#!/usr/bin/env python3
"""Minimal PostgreSQL client (Python 3 standard library only).

Used by scripts/db-verify.sh when `psql` is not available (for example with the
portable "embedded" PostgreSQL builds that ship only initdb/pg_ctl/postgres).

It speaks the v3 wire protocol, supports only `trust` authentication (the
throwaway verification cluster is created with --auth=trust and listens on
127.0.0.1 only) and sends each file as ONE simple-query message. PostgreSQL then
executes the statements in order and stops at the first error, which matches
`psql -v ON_ERROR_STOP=1 -f file` closely enough for migrations and tests:

* statements outside explicit BEGIN/COMMIT run in one implicit transaction,
* explicit `begin; ... rollback;` blocks behave exactly as in psql.

Notices (RAISE NOTICE) are printed as `NOTICE:  <message>`; errors as
`ERROR:  <message>` plus DETAIL/HINT/WHERE and the line number in the file.
Exit status: 0 on success, 1 on SQL error, 2 on connection/usage error.

LOCAL VERIFICATION TOOL ONLY - never point it at a production database.
"""
import argparse
import socket
import struct
import sys

PROTOCOL_V3 = 196608


class PgError(Exception):
    pass


class Connection:
    def __init__(self, host, port, user, dbname, timeout=600):
        if host.startswith("/"):
            self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self.sock.settimeout(timeout)
            self.sock.connect("%s/.s.PGSQL.%d" % (host.rstrip("/"), port))
        else:
            self.sock = socket.create_connection((host, port), timeout=timeout)
        self.buffer = b""
        params = {
            "user": user,
            "database": dbname,
            "client_encoding": "UTF8",
            "application_name": "zuno-pgwire",
            "DateStyle": "ISO",
        }
        payload = struct.pack("!i", PROTOCOL_V3)
        for key, value in params.items():
            payload += key.encode() + b"\0" + value.encode() + b"\0"
        payload += b"\0"
        self.sock.sendall(struct.pack("!i", len(payload) + 4) + payload)
        while True:
            kind, body = self._read_message()
            if kind == b"R":
                (code,) = struct.unpack("!i", body[:4])
                if code != 0:
                    raise PgError("unsupported authentication method %d (use trust auth)" % code)
            elif kind == b"E":
                raise PgError(_format_error(_parse_fields(body), None))
            elif kind == b"Z":
                return
            # ParameterStatus (S), BackendKeyData (K), NoticeResponse (N) ignored during startup

    def _recv_exact(self, n):
        while len(self.buffer) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise PgError("server closed the connection unexpectedly")
            self.buffer += chunk
        data, self.buffer = self.buffer[:n], self.buffer[n:]
        return data

    def _read_message(self):
        header = self._recv_exact(5)
        kind = header[:1]
        (length,) = struct.unpack("!i", header[1:5])
        body = self._recv_exact(length - 4)
        return kind, body

    def query(self, sql, out=sys.stdout, print_rows=True, source_name=None):
        body = sql.encode("utf-8") + b"\0"
        self.sock.sendall(b"Q" + struct.pack("!i", len(body) + 4) + body)
        error = None
        rows = []
        while True:
            kind, payload = self._read_message()
            if kind == b"T":
                pass
            elif kind == b"D":
                (count,) = struct.unpack("!h", payload[:2])
                pos = 2
                row = []
                for _ in range(count):
                    (size,) = struct.unpack("!i", payload[pos:pos + 4])
                    pos += 4
                    if size == -1:
                        row.append(None)
                    else:
                        row.append(payload[pos:pos + size].decode("utf-8"))
                        pos += size
                rows.append(row)
                if print_rows:
                    out.write("\t".join("" if v is None else v for v in row) + "\n")
            elif kind == b"N":
                fields = _parse_fields(payload)
                out.write("%s:  %s\n" % (fields.get("V", fields.get("S", "NOTICE")), fields.get("M", "")))
            elif kind == b"E":
                error = _format_error(_parse_fields(payload), sql, source_name)
            elif kind in (b"G", b"H", b"W"):
                error = "COPY is not supported by pgwire.py"
                # Abort the copy so the server returns to idle.
                msg = b"COPY not supported\0"
                self.sock.sendall(b"f" + struct.pack("!i", len(msg) + 4) + msg)
            elif kind == b"Z":
                break
            # C (CommandComplete), I (EmptyQuery), S (ParameterStatus), A (Notification) ignored
        out.flush()
        if error:
            raise PgError(error)
        return rows

    def close(self):
        try:
            self.sock.sendall(b"X" + struct.pack("!i", 4))
        except OSError:
            pass
        self.sock.close()


def _parse_fields(payload):
    fields = {}
    for part in payload.split(b"\0"):
        if part:
            fields[chr(part[0])] = part[1:].decode("utf-8", "replace")
    return fields


def _format_error(fields, sql, source_name=None):
    lines = ["%s:  %s" % (fields.get("V", fields.get("S", "ERROR")), fields.get("M", "unknown error"))]
    if fields.get("C"):
        lines.append("SQLSTATE: %s" % fields["C"])
    if fields.get("D"):
        lines.append("DETAIL:  %s" % fields["D"])
    if fields.get("H"):
        lines.append("HINT:  %s" % fields["H"])
    if fields.get("W"):
        lines.append("CONTEXT:  %s" % fields["W"].replace("\n", "\n          "))
    if fields.get("P") and sql:
        try:
            offset = int(fields["P"]) - 1
            line_no = sql[:offset].count("\n") + 1
            line_text = sql.splitlines()[line_no - 1] if sql.splitlines() else ""
            lines.append("LINE %d%s: %s" % (line_no, " of " + source_name if source_name else "", line_text.strip()))
        except (ValueError, IndexError):
            pass
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--host", default="127.0.0.1", help="host name or unix socket directory")
    parser.add_argument("--port", type=int, default=5432)
    parser.add_argument("--user", default="postgres")
    parser.add_argument("--dbname", default="postgres")
    parser.add_argument("-f", "--file", action="append", default=[], help="SQL file to execute (repeatable)")
    parser.add_argument("-c", "--command", action="append", default=[], help="SQL command to execute (repeatable)")
    parser.add_argument("--no-rows", action="store_true", help="do not print result rows")
    args = parser.parse_args()

    if not args.file and not args.command:
        parser.error("nothing to execute: pass -f FILE or -c SQL")

    try:
        conn = Connection(args.host, args.port, args.user, args.dbname)
    except (OSError, PgError) as exc:
        sys.stderr.write("pgwire: connection failed: %s\n" % exc)
        return 2

    status = 0
    try:
        for command in args.command:
            conn.query(command, print_rows=not args.no_rows, source_name="-c")
        for path in args.file:
            with open(path, "r", encoding="utf-8") as handle:
                sql = handle.read()
            conn.query(sql, print_rows=not args.no_rows, source_name=path)
    except PgError as exc:
        sys.stdout.flush()
        sys.stderr.write(str(exc) + "\n")
        status = 1
    except OSError as exc:
        sys.stderr.write("pgwire: I/O error: %s\n" % exc)
        status = 2
    finally:
        conn.close()
    return status


if __name__ == "__main__":
    sys.exit(main())
