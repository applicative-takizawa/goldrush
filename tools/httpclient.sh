#!/bin/sh -f

# 第一引数：環境設定ファイル
#  以下の変数が定義されている事
#    RAILS_ROOT  : railsアプリケーションのルートディレクトリへの絶対パス
#    RUBY        : rubyの実行ファイルへの絶対パス
. $1
shift 1

# 第二引数以降：Rubyスクリプトのパラメータ

umask 002

cd ${RAILS_ROOT}
${RUBY} tools/httpclients.rb $*
