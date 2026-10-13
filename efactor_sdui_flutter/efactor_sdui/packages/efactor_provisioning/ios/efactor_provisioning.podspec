Pod::Spec.new do |s|
  s.name             = 'efactor_provisioning'
  s.version          = '0.0.1'
  s.summary          = 'eFactor IoT provisioning + cloud plugin (iOS, compiled).'
  s.description      = 'Closed-source compiled iOS native lib for the eFactor plugin.'
  s.homepage         = 'https://efactor.tech'
  s.license          = { :type => 'Apache-2.0' }
  s.author           = { 'Factor Enovations Pvt Ltd' => 'dev@efactor.tech' }
  s.source           = { :path => '.' }
  s.vendored_frameworks = 'efactor_provisioning.xcframework'
  s.dependency 'Flutter'
  s.platform = :ios, '15.0'
  s.swift_version = '5.0'
end
