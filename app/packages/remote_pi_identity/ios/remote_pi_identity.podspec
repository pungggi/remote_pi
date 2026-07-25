Pod::Spec.new do |s|
  s.name             = 'remote_pi_identity'
  s.version          = '0.2.0'
  s.summary          = 'Owner-key Ed25519 identity synced via iCloud Keychain.'
  s.description      = <<-DESC
Owner-key Ed25519 identity for Remote Pi, persisted as a generic-password
Keychain item with kSecAttrSynchronizable=true so it propagates between
devices of the same Apple ID via iCloud Keychain.
                       DESC
  s.homepage         = 'https://github.com/pungggi/remote_pi'
  s.license          = { :type => 'Proprietary', :text => 'Internal use only' }
  s.author           = { 'ngSoftware' => 'alessandro@pungitore.ch' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform         = :ios, '18.0'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
  }
  s.swift_version = '5.0'
end
