Pod::Spec.new do |s|
  s.name             = 'bakometr_native'
  s.version          = '1.0.0'
  s.summary          = 'Natywne funkcje Bąkometru.'
  s.description      = 'Pomiar światła kamerą, wibracje, powiadomienia lokalne.'
  s.homepage         = 'https://github.com/'
  s.license          = { :type => 'MIT' }
  s.author           = { 'Bakometr' => 'dev@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform         = :ios, '13.0'
  s.swift_version    = '5.0'
  s.frameworks       = 'AVFoundation', 'AudioToolbox', 'UserNotifications'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
