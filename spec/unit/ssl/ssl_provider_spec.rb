require 'spec_helper'

describe Puppet::SSL::SSLProvider do
  include PuppetSpec::Files

  def pem_content(name)
    File.read(my_fixture(name))
  end

  def cert(name)
    OpenSSL::X509::Certificate.new(pem_content(name))
  end

  def crl(name)
    OpenSSL::X509::CRL.new(pem_content(name))
  end

  def key(name)
    OpenSSL::PKey::RSA.new(pem_content(name))
  end

  def request(name)
    OpenSSL::X509::Request.new(pem_content(name))
  end

  let(:global_cacerts) { [ cert('ca.pem'), cert('intermediate.pem') ] }
  let(:global_crls) { [ crl('crl.pem'), crl('intermediate-crl.pem') ] }
  let(:wrong_key) { OpenSSL::PKey::RSA.new(512) }

  context 'when creating an insecure context' do
    let(:sslctx) { subject.create_insecure_context }

    it 'has an empty list of trusted certs' do
      expect(sslctx.trusted_certs).to eq([])
    end

    it 'has an empty list of crls' do
      expect(sslctx.crls).to eq([])
    end

    it 'has an empty chain' do
      expect(sslctx.client_chain).to eq([])
    end

    it 'has a nil private key and cert' do
      expect(sslctx.private_key).to be_nil
      expect(sslctx.client_cert).to be_nil
    end

    it 'does not authenticate the server' do
      expect(sslctx.verify_peer).to eq(false)
    end
  end

  context 'when creating an root ssl context with CA certs' do
    let(:config) { { cacerts: [], crls: [], revocation: false } }

    it 'accepts empty list of certs and crls' do
      sslctx = subject.create_root_context(config)
      expect(sslctx.trusted_certs).to eq([])
      expect(sslctx.crls).to eq([])
    end

    it 'accepts valid root certs' do
      certs = [cert('ca.pem')]
      sslctx = subject.create_root_context(config.merge(cacerts: certs))
      expect(sslctx.trusted_certs).to eq(certs)
    end

    it 'accepts valid intermediate certs' do
      certs = [cert('ca.pem'), cert('intermediate.pem')]
      sslctx = subject.create_root_context(config.merge(cacerts: certs))
      expect(sslctx.trusted_certs).to eq(certs)
    end

    it 'accepts expired CA certs' do
      expired = [cert('ca.pem'), cert('intermediate.pem')]
      expired.each { |x509| x509.not_after = Time.at(0) }

      sslctx = subject.create_root_context(config.merge(cacerts: expired))
      expect(sslctx.trusted_certs).to eq(expired)
    end
  end

  context 'when creating an ssl context with crls' do
    let(:config) { { cacerts: global_cacerts, crls: global_crls} }

    it 'accepts valid CRLs' do
      certs = [cert('ca.pem')]
      crls = [crl('crl.pem')]
      sslctx = subject.create_root_context(config.merge(cacerts: certs, crls: crls))
      expect(sslctx.crls).to eq(crls)
    end

    it 'accepts valid CRLs for intermediate certs' do
      certs = [cert('ca.pem'), cert('intermediate.pem')]
      crls = [crl('crl.pem'), crl('intermediate-crl.pem')]
      sslctx = subject.create_root_context(config.merge(cacerts: certs, crls: crls))
      expect(sslctx.crls).to eq(crls)
    end

    it 'accepts expired CRLs' do
      expired = [crl('crl.pem'), crl('intermediate-crl.pem')]
      expired.each { |x509| x509.last_update = Time.at(0) }

      sslctx = subject.create_root_context(config.merge(crls: expired))
      expect(sslctx.crls).to eq(expired)
    end
  end

  context 'when creating an ssl context with client certs' do
    let(:client_cert) { cert('signed.pem') }
    let(:private_key) { key('signed-key.pem') }
    let(:config) { { cacerts: global_cacerts, crls: global_crls, client_cert: client_cert, private_key: private_key } }

    it 'accepts RSA keys' do
      sslctx = subject.create_context(config)
      expect(sslctx.private_key).to eq(private_key)
    end

    it 'raises if private key is unsupported' do
      ec_key = OpenSSL::PKey::EC.new
      expect {
        subject.create_context(config.merge(private_key: ec_key))
      }.to raise_error(Puppet::SSL::SSLError, /Unsupported key 'OpenSSL::PKey::EC'/)
    end

    it 'resolves the client chain from leaf to root' do
      sslctx = subject.create_context(config)
      expect(
        sslctx.client_chain.map(&:subject).map(&:to_s)
      ).to eq(['/CN=signed', '/CN=Test CA Subauthority', '/CN=Test CA'])
    end

    it 'raises if client cert signature is invalid' do
      client_cert.sign(wrong_key, OpenSSL::Digest::SHA256.new)
      expect {
        subject.create_context(config.merge(client_cert: client_cert))
      }.to raise_error(Puppet::SSL::CertVerifyError,
                       "Invalid signature for certificate '/CN=signed'")
    end

    it 'raises if client cert and private key are mismatched' do
      expect {
        subject.create_context(config.merge(private_key: wrong_key))
      }.to raise_error(Puppet::SSL::SSLError,
                       "The certificate for '/CN=signed' does not match its private key")
    end

    it "raises if client cert's public key has been replaced" do
      expect {
        subject.create_context(config.merge(client_cert: cert('tampered-cert.pem')))
      }.to raise_error(Puppet::SSL::CertVerifyError,
                       "Invalid signature for certificate '/CN=signed'")
    end

    # This option is only available in openssl 1.1
    it 'raises if root cert signature is invalid', if: defined?(OpenSSL::X509::V_FLAG_CHECK_SS_SIGNATURE) do
      ca = global_cacerts.first
      ca.sign(wrong_key, OpenSSL::Digest::SHA256.new)

      expect {
        subject.create_context(config.merge(cacerts: global_cacerts))
      }.to raise_error(Puppet::SSL::CertVerifyError,
                       "Invalid signature for certificate '/CN=Test CA'")
    end

    it 'raises if intermediate CA signature is invalid' do
      int = global_cacerts.last
      int.sign(wrong_key, OpenSSL::Digest::SHA256.new)

      expect {
        subject.create_context(config.merge(cacerts: global_cacerts))
      }.to raise_error(Puppet::SSL::CertVerifyError,
                       "Invalid signature for certificate '/CN=Test CA Subauthority'")
    end

    it 'raises if CRL signature for root CA is invalid', unless: Puppet::Util::Platform.jruby? do
      crl = global_crls.first
      crl.sign(wrong_key, OpenSSL::Digest::SHA256.new)

      expect {
        subject.create_context(config.merge(crls: global_crls))
      }.to raise_error(Puppet::SSL::CertVerifyError,
                       "Invalid signature for CRL issued by '/CN=Test CA'")
    end

    it 'raises if CRL signature for intermediate CA is invalid', unless: Puppet::Util::Platform.jruby? do
      crl = global_crls.last
      crl.sign(wrong_key, OpenSSL::Digest::SHA256.new)

      expect {
        subject.create_context(config.merge(crls: global_crls))
      }.to raise_error(Puppet::SSL::CertVerifyError,
                       "Invalid signature for CRL issued by '/CN=Test CA Subauthority'")
    end

    it 'raises if client cert is revoked' do
      expect {
        subject.create_context(config.merge(private_key: key('revoked-key.pem'), client_cert: cert('revoked.pem')))
      }.to raise_error(Puppet::SSL::CertVerifyError,
                       "Certificate '/CN=revoked' is revoked")
    end

    it 'raises if intermediate issuer is missing' do
      expect {
        subject.create_context(config.merge(cacerts: [cert('ca.pem')]))
      }.to raise_error(Puppet::SSL::CertVerifyError,
                       "The issuer '/CN=Test CA Subauthority' of certificate '/CN=signed' cannot be found locally")
    end

    it 'raises if root issuer is missing' do
      expect {
        subject.create_context(config.merge(cacerts: [cert('intermediate.pem')]))
      }.to raise_error(Puppet::SSL::CertVerifyError,
                       "The issuer '/CN=Test CA' of certificate '/CN=Test CA Subauthority' is missing")
    end

    it 'raises if cert is not valid yet', unless: Puppet::Util::Platform.jruby? do
      client_cert.not_before = Time.now + (5 * 60 * 60)
      expect {
        subject.create_context(config.merge(client_cert: client_cert))
      }.to raise_error(Puppet::SSL::CertVerifyError,
                       "The certificate '/CN=signed' is not yet valid, verify time is synchronized")
    end

    it 'raises if cert is expired', unless: Puppet::Util::Platform.jruby? do
      client_cert.not_after = Time.at(0)
      expect {
        subject.create_context(config.merge(client_cert: client_cert))
      }.to raise_error(Puppet::SSL::CertVerifyError,
                       "The certificate '/CN=signed' has expired, verify time is synchronized")
    end

    it 'raises if crl is not valid yet', unless: Puppet::Util::Platform.jruby? do
      future_crls = global_crls
      # invalidate the CRL issued by the root
      future_crls.first.last_update = Time.now + (5 * 60 * 60)

      expect {
        subject.create_context(config.merge(crls: future_crls))
      }.to raise_error(Puppet::SSL::CertVerifyError,
                       "The CRL issued by '/CN=Test CA' is not yet valid, verify time is synchronized")
    end

    it 'raises if crl is expired', unless: Puppet::Util::Platform.jruby? do
      past_crls = global_crls
      # invalidate the CRL issued by the root
      past_crls.first.next_update = Time.at(0)

      expect {
        subject.create_context(config.merge(crls: past_crls))
      }.to raise_error(Puppet::SSL::CertVerifyError,
                       "The CRL issued by '/CN=Test CA' has expired, verify time is synchronized")
    end

    it 'raises if the root CRL is missing' do
      crls = [crl('intermediate-crl.pem')]
      expect {
        subject.create_context(config.merge(crls: crls, revocation: :chain))
      }.to raise_error(Puppet::SSL::CertVerifyError,
                       "The CRL issued by '/CN=Test CA' is missing")
    end

    it 'raises if the intermediate CRL is missing' do
      crls = [crl('crl.pem')]
      expect {
        subject.create_context(config.merge(crls: crls))
      }.to raise_error(Puppet::SSL::CertVerifyError,
                       "The CRL issued by '/CN=Test CA Subauthority' is missing")
    end

    it "doesn't raise if the root CRL is missing and we're just checking the leaf" do
      crls = [crl('intermediate-crl.pem')]
      subject.create_context(config.merge(crls: crls, revocation: :leaf))
    end

    it "doesn't raise if the intermediate CRL is missing and revocation checking is disabled" do
      crls = [crl('crl.pem')]
      subject.create_context(config.merge(crls: crls, revocation: false))
    end

    it "doesn't raise if both CRLs are missing and revocation checking is disabled" do
      subject.create_context(config.merge(crls: [], revocation: false))
    end

    # OpenSSL < 1.1 does not verify basicConstraints
    it "raises if root CA's isCA basic constraint is false", unless: Puppet::Util::Platform.jruby? || OpenSSL::OPENSSL_VERSION_NUMBER < 0x10100000 do
      certs = [cert('bad-basic-constraints.pem'), cert('intermediate.pem')]

      expect {
        subject.create_context(config.merge(cacerts: certs, crls: [], revocation: false))
      }.to raise_error(Puppet::SSL::CertVerifyError,
                       "Certificate '/CN=Test CA' failed verification (24): invalid CA certificate")
    end

    # OpenSSL < 1.1 does not verify basicConstraints
    it "raises if intermediate CA's isCA basic constraint is false", unless: Puppet::Util::Platform.jruby? || OpenSSL::OPENSSL_VERSION_NUMBER < 0x10100000 do
      certs = [cert('ca.pem'), cert('bad-int-basic-constraints.pem')]

      expect {
        subject.create_context(config.merge(cacerts: certs, crls: [], revocation: false))
      }.to raise_error(Puppet::SSL::CertVerifyError,
                       "Certificate '/CN=Test CA Subauthority' failed verification (24): invalid CA certificate")
    end

    it 'accepts CA certs in any order' do
      sslctx = subject.create_context(config.merge(cacerts: global_cacerts.reverse))
      # certs in ruby+openssl 1.0.x are not comparable, so compare subjects
      expect(sslctx.client_chain.map(&:subject).map(&:to_s)).to contain_exactly('/CN=Test CA', '/CN=Test CA Subauthority', '/CN=signed')
    end

    it 'accepts CRLs in any order' do
      sslctx = subject.create_context(config.merge(crls: global_crls.reverse))
      # certs in ruby+openssl 1.0.x are not comparable, so compare subjects
      expect(sslctx.client_chain.map(&:subject).map(&:to_s)).to contain_exactly('/CN=Test CA', '/CN=Test CA Subauthority', '/CN=signed')
    end
  end

  context 'when verifying requests' do
    let(:csr) { request('request.pem') }

    it 'accepts valid requests' do
      private_key = key('request-key.pem')
      expect(subject.verify_request(csr, private_key.public_key)).to eq(csr)
    end

    it "raises if the CSR was signed by a private key that doesn't match public key" do
      expect {
        subject.verify_request(csr, wrong_key.public_key)
      }.to raise_error(Puppet::SSL::SSLError,
                       "The CSR for host '/CN=pending' does not match the public key")
    end

    it "raises if the CSR was tampered with" do
      csr = request('tampered-csr.pem')
      expect {
        subject.verify_request(csr, csr.public_key)
      }.to raise_error(Puppet::SSL::SSLError,
                       "The CSR for host '/CN=signed' does not match the public key")
    end
  end
end
