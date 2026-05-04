Pod::Spec.new do |spec|
  spec.name = 'Bolt'
  spec.version = '0.2.0'
  spec.summary = 'A fast, lightweight dependency injection framework for Swift.'
  spec.homepage = 'https://github.com/mibattaglia/bolt-di'
  spec.license = { :type => 'Proprietary' }
  spec.authors = { 'Michael Battaglia' => 'michaelbattaglia@users.noreply.github.com' }
  spec.source = { :git => 'https://github.com/mibattaglia/bolt-di.git', :tag => spec.version.to_s }

  spec.swift_versions = ['6.0']
  spec.module_name = 'Bolt'
  spec.ios.deployment_target = '17.0'
  spec.macos.deployment_target = '15.0'
  spec.watchos.deployment_target = '10.0'

  spec.source_files = 'Sources/Bolt/**/*.swift'
end
