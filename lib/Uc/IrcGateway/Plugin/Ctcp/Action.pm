package Uc::IrcGateway::Plugin::Ctcp::Action;
use 5.014;
use parent 'Class::Component::Plugin';
use Uc::IrcGateway::Common;

sub action :CtcpEvent('ACTION') {
}

1;
