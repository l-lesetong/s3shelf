using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Xml.Serialization;
using Amazon;
using Amazon.Runtime;
using Amazon.Runtime.CredentialManagement;
using Amazon.S3;

namespace S3Shelf
{
    public enum Authentication { AccessKeys, AwsProfile, Anonymous }

    public sealed class Connection
    {
        public string Name { get; set; } = "S3";
        public string Region { get; set; } = "";
        public string Endpoint { get; set; } = "";
        public string Profile { get; set; } = "default";
        public string PreferredBucket { get; set; } = "";
        public string CaBundle { get; set; } = "";
        public bool SkipTlsVerification { get; set; }
        public bool RequesterPays { get; set; }
        public bool PathStyle { get; set; }
        public Authentication Authentication { get; set; }
        public string ProtectedCredentials { get; set; } = "";

        [XmlIgnore]
        internal string RegionLabel => string.IsNullOrWhiteSpace(Region) ? "自动" : Region.Trim();
        internal RequestPayer Payer => RequesterPays && Authentication != Authentication.Anonymous ? RequestPayer.Requester : null;

        internal static Uri ParseEndpoint(string endpoint)
        {
            if (!Uri.TryCreate(endpoint, UriKind.Absolute, out var uri) ||
                (uri.Scheme != Uri.UriSchemeHttp && uri.Scheme != Uri.UriSchemeHttps) ||
                uri.Host.Length == 0 || uri.UserInfo.Length > 0 || uri.Query.Length > 0 || uri.Fragment.Length > 0)
                return null;
            return uri;
        }

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
            CredentialProfile profile = null;
            AWSCredentials credentials;
            if (Authentication == Authentication.AwsProfile)
            {
                var profileName = string.IsNullOrWhiteSpace(Profile) ? "default" : Profile.Trim();
                var chain = new CredentialProfileStoreChain();
                if (!chain.TryGetProfile(profileName, out profile) ||
                    !AWSCredentialsFactory.TryGetAWSCredentials(profile, chain, out credentials))
                    throw new InvalidOperationException("找不到可用的 AWS Profile「" + profileName + "」。");
            }
            else if (Authentication == Authentication.Anonymous) credentials = new AnonymousAWSCredentials();
            else
            {
                var fields = Credentials();
                credentials = string.IsNullOrEmpty(fields[2])
                    ? (AWSCredentials)new BasicAWSCredentials(fields[0], fields[1])
                    : new SessionAWSCredentials(fields[0], fields[1], fields[2]);
            }

            var region = ResolveRegion(profile);
            var endpoint = string.IsNullOrWhiteSpace(Endpoint) ? null : ParseEndpoint(Endpoint.Trim());
            if (endpoint == null && !string.IsNullOrWhiteSpace(Endpoint))
                throw new InvalidOperationException("请输入有效的 HTTP 或 HTTPS 端点。");
            var config = new AmazonS3Config { ForcePathStyle = PathStyle };
            if (endpoint == null) config.RegionEndpoint = RegionEndpoint.GetBySystemName(region);
            else
            {
                config.ServiceURL = Endpoint.Trim();
                config.AuthenticationRegion = region;
                config.RequestChecksumCalculation = RequestChecksumCalculation.WHEN_REQUIRED;
                config.ResponseChecksumValidation = ResponseChecksumValidation.WHEN_REQUIRED;
            }
            if (endpoint?.Scheme == Uri.UriSchemeHttps && (SkipTlsVerification || !string.IsNullOrWhiteSpace(CaBundle)))
                return new EndpointTlsClient(credentials, config, endpoint, SkipTlsVerification ? null : EndpointCaBundle.Load(CaBundle));
            return new AmazonS3Client(credentials, config);
        }

        private string ResolveRegion(CredentialProfile profile) =>
            new[] { Region, Environment.GetEnvironmentVariable("AWS_REGION"),
                Environment.GetEnvironmentVariable("AWS_DEFAULT_REGION"), profile?.Region?.SystemName }
                .FirstOrDefault(region => !string.IsNullOrWhiteSpace(region))?.Trim() ?? "us-east-1";

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
