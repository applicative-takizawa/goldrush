# -*- encoding: utf-8 -*-
require 'nkf'
require 'string_util'
require 'zen2han'
class ImportMail < ActiveRecord::Base

  belongs_to :business_partner
  belongs_to :bp_pic
  has_many :bp_members
  has_many :biz_offers
  has_many :tag_details, :foreign_key  => :parent_id, :conditions => "tag_details.tag_key = 'import_mails'"
  has_many :outflow_mails, :conditions => "outflow_mails.deleted = 0"

  def ImportMail.tryConv(map, header_key, &block)
    begin
      if block_given?
        return block.call
      else
        return map[header_key].to_s
      end
    rescue Encoding::UndefinedConversionError
      return NKF.nkf('-w', map.header[header_key].value)
    end
  end

  def ImportMail.import_reply_mail(m, src)
    ImportMail.import_mail_in(m, src, true)
  end

  def ImportMail.import_mail(m, src)
    open(File.join(Dir.tmpdir, 'goldrush_import_mail.lock'), 'w') do |f|
      begin
        f.flock(File::LOCK_EX)
        ImportMail.import_mail_in(m, src)
      ensure
        f.flock(File::LOCK_UN)
      end
    end
  end
  
  def make_import_mail(m)
    now = Time.now
    self.received_at = m.date.blank? ? now : m.date
    subject = ImportMail.tryConv(m, 'Subject') { m.subject }
    self.mail_subject = subject.blank? ? 'unknown subject' : subject
    self.mail_from = m.from != nil ? m.from[0].to_s : "unknown"
    unless SysConfig.email_prodmode?
      self.mail_from = StringUtil.to_test_address(self.mail_from)
    end
    self.set_bp
    self.mail_sender_name = ImportMail.tryConv(m,'From')
    self.mail_to = ImportMail.tryConv(m,'To')
    self.mail_cc = ImportMail.tryConv(m,'Cc')
    self.mail_bcc = ImportMail.tryConv(m,'Bcc')
    self.message_id = m.message_id
    self.in_reply_to = m.in_reply_to
  end

  def detect_deliverty_mail(reply_mode)
    dmt = self.in_reply_to && DeliveryMailTarget.where(message_id: self.in_reply_to).first
    if((dmt != nil) && (dmt.delivery_mail_id != nil))
      self.delivery_mail_id = dmt.delivery_mail_id
    else
      # リプライモード時、リプライでなければ取り込み中止
      if (!self.mail_from.include?("forwarding-noreply@google.com")) && reply_mode
        puts "SKIP IMPORT: reply_mode and not match in_reply_to"
        SystemLog.warn('import mail', 'to member private', self.inspect , 'import mail')
	return false
      end
	
#      # 配信メールへの返信でなくて、ユーザーのメールアドレス宛だった場合、
#      # ユーザーへの個人的なメールとみなして取り込みを中止する。
#      User.getUsers.each do |user|
#        if self.mail_to.include?(user.email)
#          puts "to member private mail: see system_logs"
#          SystemLog.warn('import mail', 'to member private', self.inspect , 'import mail')
#          return false
#        end
#      end
    end
    return true
  end

  # メールを取り込む
  #  m   : 取り込むMailオブジェクト
  #  src : 取り込むメールのソーステキスト
  def ImportMail.import_mail_in(m, src, reply_mode=false)
    attachment_flg = 0
    import_mail_id = nil
    ActiveRecord::Base::transaction do
      import_mail = ImportMail.new
      import_mail.make_import_mail(m)
      return unless import_mail.detect_deliverty_mail(reply_mode)

      # プロセス間で同期をとるために何でもいいから存在するレコードをロック(users#1 => systemユーザー)
      #User.find(1, :lock => true)
      
      if ImportMail.where(message_id: import_mail.message_id, deleted: 0).first || ImportMail.where(mail_from: import_mail.mail_from, mail_subject: import_mail.mail_subject,received_at: ((import_mail.received_at - 1.hour) .. import_mail.received_at + 1.hour), deleted: 0).first
        puts "mail duplicated: see system_logs"
        SystemLog.warn('import mail', 'mail duplicated', import_mail.inspect , 'import mail')
        return
      end
      
      # attempt_fileのため(import_mail_idが必要)に一旦登録
      import_mail.save!
      import_mail_src = ImportMailSource.new
      import_mail_src.import_mail_id = import_mail.id
      import_mail_src.message_source = src
      import_mail_src.created_user = 'import_mail'
      import_mail_src.updated_user = 'import_mail'
      import_mail_src.save!
      
      # 添付ファイルがなければ案件、あれば人材と割り切る
      import_mail.biz_offer_flg = 1
      import_mail.bp_member_flg = 0
      #---------- mail_body ここから ----------
      if m.multipart?
        # パートに分かれている(=返信元メールや添付ファイルが存在している)場合
        m.parts.each do |part|
          if part.content_type.include?('multipart/alternative')
            # multipart/alternativeの場合、メール本文の含まれるパートなので、さらにその中のパートを調べる。
            part.parts.each do |ppart|
              if ppart.content_type == 'text/plain'
                # text/plainの場合、メール本文（返信だと添付ファイルの可能性も・・・）。
                import_mail.mail_body = get_encode_body(m, ppart.body)
                break
              end # ppart.content_type == 'text/plain'
            end # part.parts.each do
            if import_mail.mail_body.blank?
              # メール本文にまだ何も代入されてない(=プレーンテキストがなかった)場合、
              # 最初のbodyの値をエンコードして代入する
              import_mail.mail_body = get_encode_body(m, part.parts[0].body)
            end # import_mail.mail_body.blank?
          elsif !part.filename.blank?
            # filenameがある = 添付ファイル
            upfile = part.body.decoded
            #part.base64_decode
            file_name = part.filename.to_s
            
            attachment_file = AttachmentFile.new
            attachment_file.create_by_import(upfile, import_mail.id, file_name)
            import_mail.biz_offer_flg = 0
            import_mail.bp_member_flg = 1

            attachment_flg = 1
          elsif part.content_type.include?('text/plain')
            # 添付ファイルでなくtext/plainの場合、メール本文。
            # 上書きされる可能性あり？
            import_mail.mail_body = get_encode_body(m, part.body)
          else
            # multipart/alternativeでもファイルでもtext/plainでもない場合は何もしない（ありえない？）
          end
        end # m.parts.each do
      else
        # パートに分かれていなければ、bodyをそのままエンコードして代入する
        import_mail.mail_body = get_encode_body(m, m.body)
      end # m.multipart?
      #---------- mail_body ここまで ----------
      import_mail.created_user = 'import_mail'
      import_mail.updated_user = 'import_mail'
      import_mail.save!
      import_mail.analyze!
      import_mail.save!

      import_mail_id = import_mail.id
      
      # JIETの案件・人材メールだった場合、案件照会・人材所属を作成
      if import_mail.jiet_ses_mail?
        if import_mail.mail_subject =~ /JIETメール配信サービス\[(..)情報\]/
          case $1
            when "案件"
              ImportMailJIET.analyze_jiet_offer(import_mail)
            when "人財"
              ImportMailJIET.analyze_jiet_human(import_mail)
          end
        end
      end

      # 流出メールだった場合、OutflowMailを作成する
      if import_mail.outflow_mail?
        OutflowMail.create_outflow_mails(import_mail)
      end

    end # transaction

    if attachment_flg == 1
      AttachmentFile.set_property_file(import_mail_id)
    end
  end
  
  def ImportMail.import
    Pop3Client.pop_mail do |m, src|
      ImportMail.import_mail(m, src)
    end # Pop3Client.pop_mail do
  end # def
  
  
  def wanted?
    self.unwanted != 1
  end

  def set_bp
    mail_from = self.mail_from
    mail_bp_pic = BpPic.find(:first, :conditions => ["deleted = 0 and email1 = ? or email2 = ?", mail_from, mail_from])
    if mail_bp_pic.blank?
      mail_business_partner = BusinessPartner.find(:first, :conditions => ["deleted = 0 and email = ?", mail_from])
      if !mail_business_partner.blank?
        self.business_partner_id = mail_business_partner.id
      end
    else
      self.bp_pic_id = mail_bp_pic.id
      self.business_partner_id = mail_bp_pic.business_partner.id
    end
  end
  
  # 取り込みメールに紐づく取引先を取得する
  def get_bizp(id)
    return BusinessPartner.find(id)
  end
  
  # 取り込みメールに紐づく取引先担当を取得する
  def get_bpic(id)
    return BpPic.find(id)
  end
  
  def attachment?
    AttachmentFile.count(:conditions => ["deleted = 0 and parent_table_name = 'import_mails' and parent_id = ?", self]) > 0
#    !AttachmentFile.find(:first, :conditions => ["deleted = 0 and parent_table_name = 'import_mails' and parent_id = ?", self]).blank?
  end
  
  def change_type(type_name)
    if type_name == "biz_offer"
      self.biz_offer_flg = 1
      self.save!
    end
  end

  def pre_body
    mail_subject + "\n" + mail_body
  end

  def detect_ages
    detect_ages_in(Tag.pre_proc_body(pre_body))
  end

  def detect_ages_in(body)
    search_pattern = /(([1-9]|[１-９])([0-9]|[０-９]))[才歳]/
    StringUtil.detect_regex(body, search_pattern) {|match_str|
      HumanResource.normalize_age(match_str)
    }.sort.reverse.first
  end

  def detect_payments
    detect_payments_in(Tag.pre_proc_body(pre_body))
  end

  def detect_payments_in(body)
    result_payments = StringUtil.detect_payments(body).map{|x| x.split("万")[0].to_f }.sort
    #案件だったら最大単価を取得、人材だったら最小単価を取得する。
    self.biz_offer_flg == 1 ? result_payments.reverse.first : result_payments.first
  end

  def detect_nearest_station
    detect_nearest_station_in(Tag.pre_proc_body(pre_body))
  end

  def detect_nearest_station_in(body)
    StringUtil.detect_regex(body, /^.*(最寄|駅).*$/).sort.reverse.first
  end
  
  def detect_proper
    detect_proper_in(Tag.pre_proc_body(pre_body))
  end
  
  # ImportMail.all.each do |x| x.proper_flg = x.detect_proper ? 1 : 0
  #   x.save!
  # end && nil
  # ImportMail.all.reject{|x| !x.detect_proper}.map{|y| y.id}
  def detect_proper_in(body)
    return false if bp_member_flg != 1
    StringUtil.detect_lines(body, /社員/) do |line|
      return true unless SpecialWord.ignore_word_propers.detect{|x| line.include?(x)}
    end
    StringUtil.detect_lines(body, /ﾌﾟﾛﾊﾟｰ/) do |line|
      return true unless SpecialWord.ignore_word_propers.detect{|x| line.include?(x)}
    end
    return false
  end

  # 人材判定用特別単語でbodyを検索して1件でもhitすれば、人材メールと判断
  def analyze_bp_member_flg(body)
    if biz_offer_flg == 1
      SpecialWord.bp_member_words.each do |word|
        unless StringUtil.detect_words(body, word).empty?
          self.biz_offer_flg = 0
          self.bp_member_flg = 1
          return
        end
      end
    end
  end

  #
  # 以下の項目に関して、メールの解析を行う
  # 年齢解析
  # 単価解析
  # 最寄駅解析
  # タグ解析
  #
  def analyze(body = Tag.pre_proc_body(pre_body))
    analyze_bp_member_flg(body)
    self.age = detect_ages_in(body)
    self.payment = detect_payments_in(body)
    self.nearest_station = detect_nearest_station_in(body)
    self.tag_text = make_tags(body)
    self.proper_flg = detect_proper_in(body) ? 1 : 0
  end

  # 解析とともに保存を行う
  def analyze!(body = Tag.pre_proc_body(pre_body))
    analyze(body)
    Tag.update_tags!("import_mails", id, tag_text)
    save!
  end
  
  # タグ生成の本体
  def make_tags(body)
    Tag.analyze_skill_tags(body)
  end

  STATION_NAME_SEPARATOR = '/:】'
  
  def nearest_station_short
    ImportMail.extract_station_name_from(self.nearest_station)
  end
  
  def ImportMail.extract_station_name_from(str)
    
    # 001：「～線～駅」にマッチする場合
    result = Zen2Han.toHan(str).strip
    result = StringUtil.detect_regex(str, /.*線(.*駅)/) do |match_str|
      match_str =~ /.*線(.*駅)/
      $1
    end
    if !result.empty?
      # 別々の商流から来た人材情報の複数の最寄り駅の記載順が違っていても同じ駅名を取得できるようにする
      result = result.sort.reverse.first.gsub(" ", "")
      return Zen2Han.toZen( StringUtil.remove_ascii_symbols( result ) )
    end
    
    # 002：空白で分割した際に「～駅」にマッチする場合
    result = Zen2Han.toHan(str)
    result = result.split(" ")
    result.each do |item|
      if !(item =~ /最寄/) && item =~ /.*駅/
        result = item
        break
      end
    end
    if result.class === String
      return Zen2Han.toZen( StringUtil.remove_ascii_symbols( result ) )
    end
    
    # 003:「最寄駅:～」にマッチする場合
    result = Zen2Han.toHan(str).gsub(" ", "")
    result = StringUtil.detect_regex(str, /最寄(り|)(駅|):(.+)/) do |match_str|
      match_str =~ /最寄(り|)(駅|):(.+)/
      $3
    end
    if !result.empty?
      result = result.sort.reverse.first
      result.gsub!(/\(.*?\)/, "") # 括弧に囲まれた部分除去
      result = StringUtil.remove_ascii_symbols( result )
      return ImportMail.add_station_sufix( Zen2Han.toZen( result ) )
    end
    
    # return nil
    
    # 以降、泥臭い処理で可能な限り駅名を抽出する
    result = Zen2Han.toHan(str).strip
    
    # 区切り文字で文字列を分割
    result_list = result.split(/[#{STATION_NAME_SEPARATOR}]/)
    
    # リストサイズが0の場合、区切り文字に空白を使用している可能性がある
    result_list = result_list[0].split(" ") if (result_list.size == 1)
    result_list.flatten!
    # ※項目と内容の区切り文字として空白を使用していない場合、
    # 　路線名と駅名の区切り文字に使っているなどのバリエーションがある為、
    #   最初の区切り文字判定に空白を含めると解析精度が落ちてしまう。
    
    # リストの各要素を最適化
    result_list.map! { |item| 
      item.strip!
      item.gsub!(/\(.*?\)/, "")   # 括弧に囲まれた部分除去
      item.gsub!(/[\(\)]/, "")    # 括弧の除去 
      item = nil if item.empty?   # 空文字列ならnilに(compact!で除去される)
      item
    }
    result_list.compact!
    
    if(result_list.size > 1)
      result_list = result_list[-1].split(" ")
      
      if(result_list.size > 1)
        temp_list = []
        for i in 0...result_list.size
          next if result_list[i] == "駅"
          temp_list.push(result_list[i]) if result_list[i] =~ /駅/ && result_list[i].size > 1
          temp_list.push(result_list[i]) if result_list[i+1] == "駅"
          temp_list.push(result_list[i]) if i-1 >= 0 && result_list[i-1] =~ /線/
        end
        result_list = temp_list.uniq
        # list.reject!{ |item| !(item =~ /駅/) }]
      end
      
      result_list.compact!
      
      # ここまでの処理でリストサイズは１になっている想定
      result = result_list[0]
      
      # 「～線 ◯◯」と書いてあり、「駅」がつかないケース
      if result =~ /線/
        result = result.split("線")[1]
      end
      
      # 文中に「◯◯駅」とだけ書いてあるケース
      if result =~ /駅/
        result = result.split("駅")[0]
      end
      
      # 複数の駅名が「or」で連結して書かれているケース
      if result =~ /or/
        result = result.split("or").sort.reverse.first
      end
      
      # 「最寄り駅」「最寄駅」「最寄」などにマッチする場合はnilを返す
      if result =~ /最寄(り|)(駅|)/
        return nil
      end
      
      # ここまで何かしら結果が得られていれば"ゴミ取り"を行う
      if result
        result.gsub!(/[:0-9a-zA-Z]/,"")
        
        # "ゴミ取り"の結果、最終的に空文字列ならnilを返す
        return nil if result.empty? 
      else
        return nil
      end
      
      # 全角に戻して結果を返す
      return ImportMail.add_station_sufix( Zen2Han.toZen(result) )
    end
    
    return nil
  end
  
  # 引数の末尾に「駅」をつける
  def ImportMail.add_station_sufix(target)
    if target[-1] != "駅"
      return target + "駅"
    else
      return target
    end
  end
  
  def ImportMail.analyze_all
    where(:deleted => 0).each do |mail|
      mail.analyze!
    end
  end

  def ImportMail.analyze_all_dry(file_name="analyze.txt")
    File.open(file_name,"w") do |f|
      where(:deleted => 0).each do |mail|
         mail.analyze
         f.puts "age: #{mail.age}"
         f.puts "pay: #{mail.payment}"
         f.puts "ner: #{mail.nearest_station}"
         f.puts "tag: #{mail.tag_text}"
      end
      nil
    end
  end

  def proper?
    proper_flg == 1
  end

  def jiet_ses_mail?
    if SysConfig.email_prodmode?
      jiet_mail_address = SysConfig.get_jiet_analysis_target_address
      (self.mail_from == jiet_mail_address) && (self.mail_subject =~ /^JIETメール配信サービス/)
    else
      #jiet_mail_address = StringUtil.to_test_address(SysConfig.get_jiet_analysis_target_address)
      # テストモードなら常にtrue
      true
    end
  end

  def outflow_mail?
    criterion = SysConfig.get_outflow_criterion.to_i
    mail_address_str = self.mail_to + self.mail_cc

    (criterion.nil? || mail_address_str.blank?) ? false : (mail_address_str.split(",").length >= criterion)
  end

private
  def ImportMail.get_encode_body(mail, body)
    if mail.content_transfer_encoding == 'ISO-2022-JP'
      return NKF.nkf('-w -J', body)
    elsif mail.content_transfer_encoding == 'UTF-8'
      return body
    else
      # そのほかは
      return NKF.nkf('-w', body.to_s)
    end
  end
  
CTYPE_TO_EXT = {
  'image/jpeg' => 'jpeg',
  'image/gif'  => 'gif',
  'image/png'  => 'png',
  'image/tiff' => 'tiff',
  'application/vnd.ms-excel' => 'xls',
  'application/msword' => 'doc'
}

def ext( mail )
  CTYPE_TO_EXT[mail.content_type] || 'txt'
end



end
