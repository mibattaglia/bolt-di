Pod::Spec.new do |spec|
  spec.name = 'Bolt'
  spec.version = '0.1.0'
  spec.summary = 'A fast, lightweight dependency injection framework for Swift.'
  spec.homepage = 'https://example.com/bolt'
  spec.license = { :type => 'MIT' }
  spec.authors = { 'Bolt' => 'bolt@example.com' }
  spec.source = { :git => 'https://example.com/bolt.git', :tag => spec.version.to_s }

  spec.swift_versions = ['6.0']
  spec.ios.deployment_target = '17.0'
  spec.macos.deployment_target = '15.0'
  spec.watchos.deployment_target = '10.0'

  spec.source_files = 'Sources/Bolt/**/*.swift'
end
