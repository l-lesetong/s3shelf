using System;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32;

namespace S3Shelf
{
    internal sealed class TransferPreferences
    {
        private const string Key = @"HKEY_CURRENT_USER\Software\s3Shelf";
        private const string Setting = "Transfers";
        private const long MiB = 1024L * 1024;
        internal int PartMiB { get; }
        internal decimal LimitMiB { get; }
        internal long PartBytes => PartMiB * MiB;
        internal long BytesPerSecond => (long)(LimitMiB * MiB);

        internal TransferPreferences(int partMiB = 8, decimal limitMiB = 0)
        {
            PartMiB = partMiB;
            LimitMiB = limitMiB;
        }

        internal static TransferPreferences Load()
        {
            try
            {
                if (Registry.GetValue(Key, Setting, null) is string[] values && values.Length == 2 &&
                    int.TryParse(values[0], NumberStyles.Integer, CultureInfo.InvariantCulture, out var part) && part >= 5 && part <= 5120 &&
                    decimal.TryParse(values[1], NumberStyles.Number, CultureInfo.InvariantCulture, out var limit) &&
                    limit >= 0 && limit <= 1000000)
                    return new TransferPreferences(part, limit);
            }
            catch (Exception error) when (error is IOException || error is UnauthorizedAccessException ||
                error is System.Security.SecurityException) { }
            return new TransferPreferences();
        }

        internal void Save() => Registry.SetValue(Key, Setting,
            new[] { PartMiB.ToString(CultureInfo.InvariantCulture), LimitMiB.ToString(CultureInfo.InvariantCulture) });
    }

    internal sealed class TransferPacer
    {
        private readonly long rate;
        private readonly Stopwatch clock = Stopwatch.StartNew();
        private double deadline;
        internal int ChunkSize { get; }

        internal TransferPacer(long rate)
        {
            this.rate = rate;
            ChunkSize = rate == 0 ? 128 * 1024 : (int)Math.Min(128 * 1024, Math.Max(1, rate / 8));
        }

        internal Task WaitAsync(int count, CancellationToken token)
        {
            token.ThrowIfCancellationRequested();
            if (rate == 0 || count == 0) return Task.CompletedTask;
            var elapsed = clock.Elapsed.TotalMilliseconds;
            deadline = Math.Max(elapsed - 15, deadline) + 1000d * count / rate;
            var delay = deadline - elapsed;
            return delay >= 12 ? Task.Delay(TimeSpan.FromMilliseconds(delay), token) : Task.CompletedTask;
        }
    }

    internal sealed class PacedUploadStream : Stream
    {
        private readonly Stream input;
        private readonly TransferPacer pacer;
        private readonly CancellationToken transferToken;

        internal PacedUploadStream(Stream input, TransferPacer pacer, CancellationToken transferToken)
        {
            this.input = input;
            this.pacer = pacer;
            this.transferToken = transferToken;
        }

        public override bool CanRead => input.CanRead;
        public override bool CanSeek => input.CanSeek;
        public override bool CanWrite => false;
        public override long Length => input.Length;
        public override long Position { get => input.Position; set => input.Position = value; }
        public override long Seek(long offset, SeekOrigin origin) => input.Seek(offset, origin);
        public override void Flush() { }
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();

        public override int Read(byte[] buffer, int offset, int count)
        {
            transferToken.ThrowIfCancellationRequested();
            var read = input.Read(buffer, offset, Math.Min(count, pacer.ChunkSize));
            pacer.WaitAsync(read, transferToken).GetAwaiter().GetResult();
            return read;
        }

        public override async Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken)
        {
            using (var linked = CancellationTokenSource.CreateLinkedTokenSource(transferToken, cancellationToken))
            {
                var read = await input.ReadAsync(buffer, offset, Math.Min(count, pacer.ChunkSize), linked.Token).ConfigureAwait(false);
                await pacer.WaitAsync(read, linked.Token).ConfigureAwait(false);
                return read;
            }
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing) input.Dispose();
            base.Dispose(disposing);
        }
    }
}
