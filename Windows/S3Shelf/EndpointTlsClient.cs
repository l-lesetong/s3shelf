using System;
using System.IO;
using System.Net.Security;
using Amazon.Runtime;
using Amazon.Runtime.Internal;
using Amazon.S3;
using Amazon.S3.Internal;

namespace S3Shelf
{
    internal sealed class EndpointTlsClient : AmazonS3Client
    {
        private static readonly RemoteCertificateValidationCallback SkipCertificateValidation =
            (sender, certificate, chain, errors) => certificate != null;

        internal EndpointTlsClient(AWSCredentials credentials, AmazonS3Config config, Uri endpoint, EndpointCaBundle caBundle)
            : base(credentials, config)
        {
            var validate = caBundle == null ? SkipCertificateValidation : new RemoteCertificateValidationCallback(caBundle.Validate);
            var factory = new EndpointRequestFactory(endpoint, !config.ForcePathStyle, validate);
            RuntimePipeline.ReplaceHandler<HttpHandler<Stream>>(new HttpHandler<Stream>(factory, this));
            RuntimePipeline.ReplaceHandler<AmazonS3RedirectHandler>(new SameOriginRedirectHandler());
        }

        private sealed class SameOriginRedirectHandler : AmazonS3RedirectHandler
        {
            protected override void FinalizeForRedirect(IExecutionContext context, string location)
            {
                var origin = context.RequestContext.Request.Endpoint;
                if (!Uri.TryCreate(location, UriKind.Absolute, out var target) || target.Scheme != origin.Scheme ||
                    target.Port != origin.Port || !target.IdnHost.Equals(origin.IdnHost, StringComparison.OrdinalIgnoreCase))
                {
                    context.ResponseContext.HttpResponse.ResponseBody?.Dispose();
                    throw new InvalidOperationException("已阻止此连接重定向到其他端点。");
                }
                base.FinalizeForRedirect(context, location);
            }
        }

        private sealed class EndpointRequestFactory : IHttpRequestFactory<Stream>
        {
            private readonly Uri endpoint;
            private readonly bool virtualHosting;
            private readonly RemoteCertificateValidationCallback validate;

            internal EndpointRequestFactory(Uri endpoint, bool virtualHosting, RemoteCertificateValidationCallback validate)
            {
                this.endpoint = endpoint;
                this.virtualHosting = virtualHosting;
                this.validate = validate;
            }

            public IHttpRequest<Stream> CreateHttpRequest(Uri uri)
            {
                // The SDK can reissue redirects. Validate the authority again for every request it creates.
                if (uri.Scheme != Uri.UriSchemeHttps || uri.Port != endpoint.Port ||
                    !(uri.IdnHost.Equals(endpoint.IdnHost, StringComparison.OrdinalIgnoreCase) ||
                    (virtualHosting && endpoint.HostNameType == UriHostNameType.Dns &&
                        uri.IdnHost.EndsWith("." + endpoint.IdnHost, StringComparison.OrdinalIgnoreCase))))
                    throw new InvalidOperationException("已阻止此连接重定向到其他 HTTPS 端点。");
                return new EndpointRequest(uri, validate);
            }

            public void Dispose() { }
        }

        private sealed class EndpointRequest : HttpRequest
        {
            private readonly RemoteCertificateValidationCallback validate;

            internal EndpointRequest(Uri uri, RemoteCertificateValidationCallback validate) : base(uri) { this.validate = validate; }

            public override void ConfigureRequest(IRequestContext context)
            {
                base.ConfigureRequest(context);
                // Set the callback after the SDK has applied its transport defaults.
                Request.ServerCertificateValidationCallback = validate;
                Request.AllowAutoRedirect = false;
            }
        }
    }
}
