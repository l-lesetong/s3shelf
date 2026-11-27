using System;
using System.Formats.Asn1;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Security;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text.RegularExpressions;

namespace S3Shelf
{
    internal sealed class EndpointCaBundle
    {
        private static readonly Regex PemCertificate = new Regex(
            "-----BEGIN CERTIFICATE-----([A-Za-z0-9+/=\\s]+)-----END CERTIFICATE-----", RegexOptions.CultureInvariant, TimeSpan.FromSeconds(1));
        private readonly byte[][] certificates;

        private EndpointCaBundle(byte[][] certificates) { this.certificates = certificates; }

        internal static EndpointCaBundle Load(string path)
        {
            try
            {
                using (var stream = File.OpenRead(path))
                using (var reader = new StreamReader(stream))
                {
                    if (stream.Length > 4 * 1024 * 1024) throw new InvalidDataException("文件超过 4 MiB。");
                    var certificates = PemCertificate.Matches(reader.ReadToEnd()).Cast<Match>()
                        .Select(match => Convert.FromBase64String(match.Groups[1].Value)).ToArray();
                    if (certificates.Length == 0) throw new InvalidDataException("文件中没有 PEM 格式的证书。");
                    foreach (var data in certificates)
                    {
                        if (X509Certificate2.GetCertContentType(data) != X509ContentType.Cert)
                            throw new InvalidDataException("文件中包含无效的 PEM 证书。");
                        using (var certificate = new X509Certificate2(data))
                        {
                            if (!certificate.RawData.SequenceEqual(data))
                                throw new InvalidDataException("文件中包含无效的 PEM 证书。");
                        }
                    }
                    return new EndpointCaBundle(certificates);
                }
            }
            catch (Exception error) when (error is IOException || error is UnauthorizedAccessException || error is ArgumentException ||
                error is FormatException || error is CryptographicException || error is RegexMatchTimeoutException ||
                error is System.Security.SecurityException)
            {
                throw new InvalidOperationException("无法读取自定义 CA。 " + error.Message, error);
            }
        }

        internal bool Validate(object sender, X509Certificate certificate, X509Chain original, SslPolicyErrors errors)
        {
            if (certificate == null || !(sender is HttpWebRequest request) ||
                (errors & ~SslPolicyErrors.RemoteCertificateChainErrors) != SslPolicyErrors.None) return false;
            using (var leaf = new X509Certificate2(certificate))
            using (var chain = new X509Chain())
            {
                if (!MatchesEndpoint(leaf, request.RequestUri.IdnHost)) return false;
                var anchors = new X509Certificate2Collection();
                try
                {
                    foreach (var data in certificates) anchors.Add(new X509Certificate2(data));
                    chain.ChainPolicy.ExtraStore.AddRange(anchors);
                    if (original != null)
                    {
                        foreach (X509ChainElement element in original.ChainElements)
                            chain.ChainPolicy.ExtraStore.Add(element.Certificate);
                    }
                    chain.ChainPolicy.RevocationMode = original?.ChainPolicy.RevocationMode ?? X509RevocationMode.NoCheck;
                    chain.ChainPolicy.ApplicationPolicy.Add(new Oid("1.3.6.1.5.5.7.3.1")); // TLS server authentication.
                    chain.ChainPolicy.VerificationFlags = X509VerificationFlags.AllowUnknownCertificateAuthority;
                    if (!chain.Build(leaf) || chain.ChainElements.Count == 0 ||
                        chain.ChainStatus.Any(status => (status.Status & ~X509ChainStatusFlags.UntrustedRoot) != X509ChainStatusFlags.NoError))
                        return false;
                    var root = chain.ChainElements[chain.ChainElements.Count - 1].Certificate;
                    return anchors.Cast<X509Certificate2>().Any(anchor => anchor.RawData.SequenceEqual(root.RawData));
                }
                catch (CryptographicException) { return false; }
                finally { foreach (X509Certificate2 anchor in anchors) anchor.Dispose(); }
            }
        }

        private static bool MatchesEndpoint(X509Certificate2 certificate, string host)
        {
            var names = certificate.Extensions["2.5.29.17"];
            var isIp = IPAddress.TryParse(host, out var address);
            if (names == null) return !isIp && DnsMatches(certificate.GetNameInfo(X509NameType.DnsName, false), host);
            try
            {
                var reader = new AsnReader(names.RawData, AsnEncodingRules.DER);
                var sequence = reader.ReadSequence();
                reader.ThrowIfNotEmpty();
                var matches = false;
                var dnsTag = new Asn1Tag(TagClass.ContextSpecific, 2);
                var ipTag = new Asn1Tag(TagClass.ContextSpecific, 7);
                while (sequence.HasData)
                {
                    var tag = sequence.PeekTag();
                    if (tag.HasSameClassAndValue(dnsTag))
                    {
                        var name = sequence.ReadCharacterString(UniversalTagNumber.IA5String, dnsTag);
                        matches |= !isIp && DnsMatches(name, host);
                    }
                    else if (tag.HasSameClassAndValue(ipTag))
                    {
                        var bytes = sequence.ReadOctetString(ipTag);
                        matches |= isIp && bytes.SequenceEqual(address.GetAddressBytes());
                    }
                    else sequence.ReadEncodedValue();
                }
                return matches;
            }
            catch (AsnContentException) { return false; }
        }

        private static bool DnsMatches(string name, string host)
        {
            if (string.IsNullOrEmpty(name)) return false;
            if (name.Equals(host, StringComparison.OrdinalIgnoreCase)) return true;
            var dot = host.IndexOf('.');
            return dot > 0 && name.StartsWith("*.", StringComparison.Ordinal) &&
                name.IndexOf('.', 2) > 2 && host.Substring(dot).Equals(name.Substring(1), StringComparison.OrdinalIgnoreCase);
        }
    }
}
