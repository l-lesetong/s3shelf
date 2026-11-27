using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Xml.Serialization;
using Amazon;
using Amazon.Runtime;
using Amazon.S3;

namespace S3Shelf
{
    public enum Authentication { AccessKeys, AwsProfile, Anonymous }

    public sealed class Connection
    {
        public string Name { get; set; } = "S3";
        public string Region { get; set; } = "us-east-1";
        public string Endpoint { get; set; } = "";
        public string Profile { get; set; } = "default";
        public bool PathStyle { get; set; }
        public Authentication Authentication { get; set; }
        public string ProtectedCredentials { get; set; } = "";

        internal string[] Credentials()
        {
            if (string.IsNullOrEmpty(ProtectedCredentials)) return new[] { "", "", "" };
            var bytes = ProtectedData.Unprotect(Convert.FromBase64String(ProtectedCredentials), null, DataProtectionScope.CurrentUser);
            return Encoding.UTF8.GetString(bytes).Split('\n');
        }

        internal void SetCredentials(string access, string secret, string token)
        {
            var bytes = Encoding.UTF8.GetBytes(string.Join("\n", access, secret, token));
            ProtectedCredentials = Convert.ToBase64String(ProtectedData.Protect(bytes, null, DataProtectionScope.CurrentUser));
        }

        internal AmazonS3Client Open()
        {
            var config = new AmazonS3Config { ForcePathStyle = PathStyle };
            if (string.IsNullOrEmpty(Endpoint)) config.RegionEndpoint = RegionEndpoint.GetBySystemName(Region);
            else
            {
                config.ServiceURL = Endpoint;
                config.AuthenticationRegion = Region;
                config.RequestChecksumCalculation = RequestChecksumCalculation.WHEN_REQUIRED;
                config.ResponseChecksumValidation = ResponseChecksumValidation.WHEN_REQUIRED;
            }
            if (Authentication == Authentication.Anonymous) return new AmazonS3Client(new AnonymousAWSCredentials(), config);
            if (Authentication == Authentication.AwsProfile)
            {
                var chain = new Amazon.Runtime.CredentialManagement.CredentialProfileStoreChain();
                if (!chain.TryGetAWSCredentials(Profile, out var credentials))
                    throw new InvalidOperationException("找不到 AWS 配置档案「" + Profile + "」。");
                return new AmazonS3Client(credentials, config);
            }
            var fields = Credentials();
            AWSCredentials keys = string.IsNullOrEmpty(fields[2])
                ? (AWSCredentials)new BasicAWSCredentials(fields[0], fields[1])
                : new SessionAWSCredentials(fields[0], fields[1], fields[2]);
            return new AmazonS3Client(keys, config);
        }

        public override string ToString() => Name;
    }

    internal static class ConnectionStore
    {
        private static readonly string Folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "s3Shelf");
        private static readonly string FileName = Path.Combine(Folder, "connections.xml");
        private static readonly XmlSerializer Serializer = new XmlSerializer(typeof(List<Connection>));

        internal static List<Connection> Load()
        {
            if (!File.Exists(FileName)) return new List<Connection>();
            using (var stream = File.OpenRead(FileName)) return (List<Connection>)Serializer.Deserialize(stream);
        }

        internal static void Save(IEnumerable<Connection> connections)
        {
            Directory.CreateDirectory(Folder);
            var temporary = Path.Combine(Folder, Guid.NewGuid().ToString("N") + ".tmp");
            try
            {
                using (var stream = File.Create(temporary)) Serializer.Serialize(stream, connections.ToList());
                if (File.Exists(FileName)) File.Replace(temporary, FileName, null);
                else File.Move(temporary, FileName);
            }
            finally { if (File.Exists(temporary)) File.Delete(temporary); }
        }
    }
}
