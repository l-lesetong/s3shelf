using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using Microsoft.Win32;

namespace S3Shelf
{
    internal sealed class DetailCache
    {
        private const string SettingsKey = @"HKEY_CURRENT_USER\Software\s3Shelf";
        private const string SettingsValue = "DetailCache";
        private const int MiB = 1024 * 1024;
        private readonly Dictionary<(Connection Connection, string Bucket, string Key, int Kind), Entry> entries =
            new Dictionary<(Connection Connection, string Bucket, string Key, int Kind), Entry>();
        private readonly LinkedList<(Connection Connection, string Bucket, string Key, int Kind)> expirationOrder =
            new LinkedList<(Connection Connection, string Bucket, string Key, int Kind)>();
        private long bytes;
        private long useOrder;
        internal long Revision { get; private set; }
        internal int Lifetime { get; private set; } = 30;
        internal int Capacity { get; private set; } = 32;

        internal DetailCache()
        {
            try
            {
                if (Registry.GetValue(SettingsKey, SettingsValue, null) is string[] setting && setting.Length == 2 &&
                    int.TryParse(setting[0], out var lifetime) && lifetime >= 0 && lifetime <= 3600 &&
                    int.TryParse(setting[1], out var capacity) && capacity >= 1 && capacity <= 64)
                {
                    Lifetime = lifetime;
                    Capacity = capacity;
                }
            }
            catch (Exception error) when (error is System.IO.IOException || error is UnauthorizedAccessException ||
                error is System.Security.SecurityException) { }
        }

        internal void Configure(int lifetime, int capacity)
        {
            Registry.SetValue(SettingsKey, SettingsValue, new[] { lifetime.ToString(), capacity.ToString() });
            RemoveExpired(Stopwatch.GetTimestamp());
            Lifetime = lifetime;
            Capacity = capacity;
            Revision++;
            RemoveExpired(Stopwatch.GetTimestamp());
            Trim((long)Capacity * MiB);
        }

        internal bool TryRead((Connection Connection, string Bucket, string Key, int Kind) key, out string text, out DateTime time)
        {
            RemoveExpired(Stopwatch.GetTimestamp());
            if (entries.TryGetValue(key, out var entry))
            {
                entry.Hits++;
                entry.LastUsed = ++useOrder;
                text = entry.Text;
                time = entry.Time;
                return true;
            }
            text = null;
            time = default;
            return false;
        }

        internal void Store((Connection Connection, string Bucket, string Key, int Kind) key, string text, long revision, long started)
        {
            if (Lifetime == 0 || Revision != revision) return;
            var now = Stopwatch.GetTimestamp();
            RemoveExpired(now);
            if (entries.TryGetValue(key, out var previous) && previous.Started > started) return;
            var entry = new Entry
            {
                Text = text, Time = DateTime.Now, Loaded = now, Started = started, LastUsed = ++useOrder,
                Hits = previous?.Hits ?? 1,
                Bytes = 256L + 2L * (text.Length + key.Bucket.Length + (key.Key?.Length ?? 0))
            };
            Remove(key);
            if (entry.Bytes > (long)Capacity * MiB) return;
            Trim((long)Capacity * MiB - entry.Bytes);
            entry.Expiration = expirationOrder.AddLast(key);
            entries[key] = entry;
            bytes += entry.Bytes;
        }

        internal void Refresh((Connection Connection, string Bucket, string Key, int Kind) key)
        {
            Revision++;
            Remove(key);
        }

        internal void Invalidate(Connection connection, string bucket = null, string key = null, bool entireBucket = false)
        {
            Revision++;
            foreach (var entry in entries.Keys.Where(item => item.Connection == connection &&
                (bucket == null || (item.Bucket == bucket && (entireBucket || item.Key == key)))).ToArray())
                Remove(entry);
        }

        private void RemoveExpired(long now)
        {
            var maxAge = (long)Lifetime * Stopwatch.Frequency;
            while (expirationOrder.First != null && now - entries[expirationOrder.First.Value].Loaded >= maxAge)
                Remove(expirationOrder.First.Value);
        }

        private void Trim(long capacity)
        {
            if (bytes <= capacity) return;
            foreach (var entry in entries.OrderBy(item => item.Value.Hits).ThenBy(item => item.Value.LastUsed).Select(item => item.Key).ToArray())
            {
                Remove(entry);
                if (bytes <= capacity) break;
            }
        }

        private void Remove((Connection Connection, string Bucket, string Key, int Kind) key)
        {
            if (!entries.TryGetValue(key, out var entry)) return;
            expirationOrder.Remove(entry.Expiration);
            entries.Remove(key);
            bytes -= entry.Bytes;
        }

        private sealed class Entry
        {
            internal string Text;
            internal DateTime Time;
            internal long Loaded, Started, LastUsed, Hits, Bytes;
            internal LinkedListNode<(Connection Connection, string Bucket, string Key, int Kind)> Expiration;
        }
    }
}
