using System;
using System.Collections.Generic;
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

    internal static class Storage
    {
        private const long PartSize = 8L * 1024 * 1024;

        internal static async Task<ObjectPage> ListAsync(IAmazonS3 client, string bucket, string prefix, string cursor, CancellationToken token)
        {
            var page = await client.ListObjectsV2Async(new ListObjectsV2Request
            {
                BucketName = bucket, Prefix = prefix, Delimiter = "/", MaxKeys = 1000, ContinuationToken = cursor
            }, token).ConfigureAwait(false);
            var folders = (page.CommonPrefixes ?? new List<string>()).Select(key => new ObjectEntry { Key = key, Folder = true });
            var objects = (page.S3Objects ?? new List<S3Object>()).Where(item => item.Key != prefix).Select(item => new ObjectEntry
            {
                Key = item.Key, Size = item.Size, Modified = item.LastModified, StorageClass = item.StorageClass?.Value
            });
            return new ObjectPage { Entries = folders.Concat(objects).ToArray(), Cursor = page.NextContinuationToken };
        }

        internal static async Task UploadAsync(IAmazonS3 client, string bucket, string key, string path, Action<long, long> progress, CancellationToken token)
        {
            using (var transfer = new TransferUtility(client, new TransferUtilityConfig { MinSizeBeforePartUpload = PartSize }))
            {
                var length = new FileInfo(path).Length;
                // Round up when the default size would exceed S3's 10,000 part limit.
                var partSize = Math.Max(PartSize, (length + 9999) / 10000);
                var request = new TransferUtilityUploadRequest { BucketName = bucket, Key = key, FilePath = path, PartSize = partSize };
                request.UploadProgressEvent += (sender, args) => progress(args.TransferredBytes, args.TotalBytes);
                await transfer.UploadAsync(request, token).ConfigureAwait(false);
                progress(length, length);
            }
        }

        internal static async Task DownloadAsync(IAmazonS3 client, string bucket, string key, string path, Action<long, long> progress, CancellationToken token)
        {
            var temporary = Path.Combine(Path.GetDirectoryName(path), ".s3shelf-" + Guid.NewGuid().ToString("N") + ".part");
            try
            {
                using (var response = await client.GetObjectAsync(bucket, key, token).ConfigureAwait(false))
                using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 128 * 1024, true))
                {
                    var buffer = new byte[128 * 1024];
                    long transferred = 0;
                    int count;
                    while ((count = await response.ResponseStream.ReadAsync(buffer, 0, buffer.Length, token).ConfigureAwait(false)) > 0)
                    {
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
