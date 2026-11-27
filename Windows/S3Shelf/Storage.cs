using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Amazon.S3;
using Amazon.S3.Model;
using Amazon.S3.Transfer;

namespace S3Shelf
{
    internal sealed class ObjectEntry
    {
        internal string Key;
        internal bool Folder;
        internal long? Size;
        internal DateTime? Modified;
        internal string StorageClass;
    }

    internal sealed class ObjectPage
    {
        internal ObjectEntry[] Entries;
        internal string Cursor;
    }

    internal sealed class ObjectPageCache
    {
        private const int MaxPages = 12;
        private static readonly long Lifetime = 45 * Stopwatch.Frequency;
        private readonly Dictionary<(Connection Source, string Bucket, string Prefix), (ObjectPage Page, long Loaded)> pages =
            new Dictionary<(Connection Source, string Bucket, string Prefix), (ObjectPage Page, long Loaded)>();
        internal long Revision { get; private set; }

        internal ObjectPage Read((Connection Source, string Bucket, string Prefix) scope)
        {
            if (!pages.TryGetValue(scope, out var cached)) return null;
            if (Stopwatch.GetTimestamp() - cached.Loaded < Lifetime) return cached.Page;
            pages.Remove(scope);
            return null;
        }

        internal void Store((Connection Source, string Bucket, string Prefix) scope, ObjectPage page, long revision)
        {
            if (revision != Revision) return;
            if (pages.Count >= MaxPages && !pages.ContainsKey(scope))
                pages.Remove(pages.OrderBy(item => item.Value.Loaded).First().Key);
            pages[scope] = (page, Stopwatch.GetTimestamp());
        }

        internal void Invalidate(Connection source, string bucket = null, string prefix = null)
        {
            Revision++;
            foreach (var scope in pages.Keys.Where(scope => scope.Source == source &&
                (bucket == null || (scope.Bucket == bucket && (prefix == null || scope.Prefix == prefix)))).ToArray())
                pages.Remove(scope);
        }
    }

    internal static class Storage
    {
        internal static async Task<ObjectPage> ListAsync(IAmazonS3 client, string bucket, string prefix, string cursor, RequestPayer payer, CancellationToken token)
        {
            var page = await client.ListObjectsV2Async(new ListObjectsV2Request
            {
                BucketName = bucket, Prefix = prefix, Delimiter = "/", MaxKeys = 1000, ContinuationToken = cursor, RequestPayer = payer
            }, token).ConfigureAwait(false);
            var folders = (page.CommonPrefixes ?? new List<string>()).Select(key => new ObjectEntry { Key = key, Folder = true });
            var objects = (page.S3Objects ?? new List<S3Object>()).Where(item => item.Key != prefix).Select(item => new ObjectEntry
            {
                Key = item.Key, Size = item.Size, Modified = item.LastModified, StorageClass = item.StorageClass?.Value
            });
            return new ObjectPage { Entries = folders.Concat(objects).ToArray(), Cursor = page.NextContinuationToken };
        }

        internal static async Task UploadAsync(IAmazonS3 client, string bucket, string key, string path, RequestPayer payer,
            TransferPreferences preferences, Action<long, long> progress, CancellationToken token)
        {
            var config = new TransferUtilityConfig { MinSizeBeforePartUpload = preferences.PartBytes };
            var limited = preferences.BytesPerSecond > 0;
            if (limited) config.ConcurrentServiceRequests = 1;
            using (var transfer = new TransferUtility(client, config))
            using (var stream = limited ? new PacedUploadStream(File.OpenRead(path), new TransferPacer(preferences.BytesPerSecond), token) : null)
            {
                var length = stream?.Length ?? new FileInfo(path).Length;
                // Round up when the default size would exceed S3's 10,000 part limit.
                var partSize = Math.Max(preferences.PartBytes, (length + 9999) / 10000);
                var request = new TransferUtilityUploadRequest { BucketName = bucket, Key = key, PartSize = partSize, RequestPayer = payer };
                request.FilePath = limited ? null : path;
                request.InputStream = stream;
                request.UploadProgressEvent += (sender, args) => progress(args.TransferredBytes, args.TotalBytes);
                await transfer.UploadAsync(request, token).ConfigureAwait(false);
                progress(length, length);
            }
        }

        internal static async Task DownloadAsync(IAmazonS3 client, string bucket, string key, string path, RequestPayer payer,
            TransferPreferences preferences, Action<long, long> progress, CancellationToken token)
        {
            var temporary = Path.Combine(Path.GetDirectoryName(path), ".s3shelf-" + Guid.NewGuid().ToString("N") + ".part");
            try
            {
                using (var response = await client.GetObjectAsync(new GetObjectRequest { BucketName = bucket, Key = key, RequestPayer = payer }, token).ConfigureAwait(false))
                using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 128 * 1024, true))
                {
                    var pacer = new TransferPacer(preferences.BytesPerSecond);
                    var buffer = new byte[pacer.ChunkSize];
                    long transferred = 0;
                    int count;
                    while ((count = await response.ResponseStream.ReadAsync(buffer, 0, buffer.Length, token).ConfigureAwait(false)) > 0)
                    {
                        await pacer.WaitAsync(count, token).ConfigureAwait(false);
                        await output.WriteAsync(buffer, 0, count, token).ConfigureAwait(false);
                        transferred += count;
                        progress(transferred, response.ContentLength);
                    }
                    if (response.ContentLength >= 0 && transferred != response.ContentLength)
                        throw new IOException("下载大小与服务端响应不一致。");
                }
                token.ThrowIfCancellationRequested();
                if (File.Exists(path)) File.Replace(temporary, path, null);
                else File.Move(temporary, path);
            }
            finally { if (File.Exists(temporary)) File.Delete(temporary); }
        }
    }
}
