fid = fopen('~/temp/polypoint/backscatter/backscatter_trace_exp8_110k_notag_wiredclk.csv','r');

%First line is useless.  Discard.
fgetl(fid);

%Parse the Saleae csv dump
spi_data = fscanf(fid,'%f,%d,0x%02X,0x%02X');
num_fields = 4;
num_rows = floor(length(spi_data)/num_fields);
spi_data = reshape(spi_data(1:num_rows*num_fields),[num_fields,num_rows]);

fclose(fid);

%Window over which to analyze data
%%backscatter_trace.csv
%start_time = 4.96607581;
%end_time = 5.28113439;
%%backscatter_trace_with_tag.csv
%start_time = 1.7165836; %first time
%end_time = 2.03164221;
start_time = 2.03164221; %second time
end_time = 2.34670082;
%%backscatter_trace_with_tag_bigger_separation.csv
%start_time = 5.11321996;
%end_time = 5.42827871;
start_time = 0;
end_time = 20;

IMP_THRESH = 0.2;
IMP_THRESH2 = 0.8;
CIR_LEN = 1016;
INTERP_MULT = 100;

%Get rid of all data that doesn't fit inside the window
spi_data = spi_data(:,((spi_data(1,:) > start_time) & (spi_data(1,:) < end_time)));

%Indices of all new SPI transactions based on ID
spi_time = spi_data(1,:);
spi_id   = spi_data(2,:);
spi_mosi = spi_data(3,:);
spi_miso = spi_data(4,:);
transaction_idxs = [1,find(diff(spi_id) > 0)+1];

%Stitch together all of the CIR data
start_cir_chunks = transaction_idxs(find(spi_mosi(transaction_idxs) == 37)) + 2;
mid_cir_chunks = transaction_idxs(find(spi_mosi(transaction_idxs) == 101)) + 4;
last_cir_chunk = max(start_cir_chunks);
start_cir_chunks = start_cir_chunks(start_cir_chunks < last_cir_chunk);
mid_cir_chunks = mid_cir_chunks(mid_cir_chunks > min(start_cir_chunks));
mid_cir_chunks = mid_cir_chunks(mid_cir_chunks < last_cir_chunk);
chunk_idxs = sort([start_cir_chunks, mid_cir_chunks]);
num_chunks = length(chunk_idxs);
num_cirs = length(start_cir_chunks);

chunk_agg_idxs = repmat(chunk_idxs.',[1,512]) + repmat(0:511,[num_chunks,1]);
chunk_data = spi_miso(chunk_agg_idxs);
chunk_data = chunk_data(:,1:2:end) + chunk_data(:,2:2:end)*256;
cir_data = reshape(chunk_data.',[2048,num_cirs]);
cir_data(cir_data >= 2^15) = cir_data(cir_data >= 2^15) - 2^16;
cir_data = cir_data(1:2:end,:) + 1i*cir_data(2:2:end,:);

%CIRs are only 4064 octets long
cir_data = cir_data(1:CIR_LEN,:);

keyboard;

%Interpolate the CIRs
cir_data_fft = fft(cir_data,[],1).*repmat(fftshift(hamming(CIR_LEN)),[1,size(cir_data,2)]);
cir_data_interp_fft = [cir_data_fft(1:CIR_LEN/2,:);zeros((INTERP_MULT-1)*CIR_LEN,num_cirs);cir_data_fft(CIR_LEN/2+1:end,:)];
cir_data_interp = ifft(cir_data_interp_fft,[],1);

%Come up with a rough estimate of ToA from each CIR
toas = zeros(num_cirs,1);
for ii=1:num_cirs
	above_thresh = find(abs(cir_data_interp(:,ii)) > max(abs(cir_data_interp(:,ii)))*IMP_THRESH);
	toas(ii) = above_thresh(1);
end

%Rotate CIRs to place ToA at zero
for ii=1:num_cirs
	cir_data_interp(:,ii) = circshift(cir_data_interp(:,ii),-toas(ii))./sqrt(sum(abs(cir_data_interp(:,ii).^2)));
end

%Figure out what the sequence numbers for each CIR are
seq_num_idxs = transaction_idxs(find(spi_mosi(transaction_idxs) == 17)) + 17;
seq_num_idxs = seq_num_idxs(2:2:end-2); %First read is always just used to determine packet length, also remove the last one as it's likely incomplete
seq_nums = spi_miso(seq_num_idxs) + 256*spi_miso(seq_num_idxs+1) + 256*256*spi_miso(seq_num_idxs+2) + 256*256*256*spi_miso(seq_num_idxs+3);

%Separate CIRs into two bins depending on where in the sequence they came from
pn_sequence = [ ...
        0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 1, ... 
        0, 0, 0, 1, 0, 1, 0, 0, 1, 1, 1, 1, ... 
        0, 1, 0, 0, 0, 1, 1, 1, 0, 0, 1, 0, ... 
        0, 1, 0, 1, 1, 0, 1, 1, 1, 0, 1, 1, ... 
        0, 0, 1, 1, 0, 1, 0, 1, 0, 1, 1, 1, ... 
        1, 1, 1];

ones_mean = zeros(length(pn_sequence),size(cir_data_interp,1));
zeros_mean = zeros(length(pn_sequence),size(cir_data_interp,1));
seq_nums_mod = mod(seq_nums, length(pn_sequence));
pn_idxs = seq_nums_mod+1;
pn_zeros = cir_data_interp(:,find(mod(seq_nums,2) == 0));
pn_ones = cir_data_interp(:,find(mod(seq_nums,2) == 1));

%%Fine-tune the shift of each CIR to minimize magnitude difference
%pn_zeros = shift_corr(pn_zeros, INTERP_MULT, 10);
%pn_zeros = shift_corr(pn_zeros, INTERP_MULT, 0.1);
%pn_ones = shift_corr(pn_ones, INTERP_MULT, 10);
%pn_ones = shift_corr(pn_ones, INTERP_MULT, 0.1);

for ii=1:size(pn_zeros,2)
	%[~,max_peak] = max(abs(pn_zeros(:,ii)));
	%pn_zeros(:,ii) = circshift(pn_zeros(:,ii),-max_peak);
	pn_zeros(:,ii) = pn_zeros(:,ii).*exp(-1i*angle(pn_zeros(1,ii)));
end
for ii=1:size(pn_ones,2)
	%[~,max_peak] = max(abs(pn_ones(:,ii)));
	%pn_ones(:,ii) = circshift(pn_ones(:,ii),-max_peak);
	pn_ones(:,ii) = pn_ones(:,ii).*exp(-1i*angle(pn_ones(1,ii)));
end
ones_mean = mean(abs(pn_ones),2);
zeros_mean = mean(abs(pn_zeros),2);
ones_mean = sum(pn_ones,2)/size(pn_ones,2);
zeros_mean = sum(pn_zeros,2)/size(pn_zeros,2);

%%Scale (and shift) each CIR so that the 20% to 80% leading edge matches the first the closest
%last_int_index = find(ones_mean > max(ones_mean)*IMP_THRESH2);
%last_int_index = last_int_index(1);
%best_shift = 0;
%best_scale = 0;
%best_fit = Inf;
%for shift = -INTERP_MULT:INTERP_MULT
%	shifted_cir = circshift(ones_mean,shift);
%	shifted_cir = shifted_cir(1:last_int_index);
%	for scale_idx = 1:last_int_index
%		scale = shifted_cir(scale_idx)/zeros_mean(scale_idx);
%		cand_fit = sum((shifted_cir/scale-zeros_mean(1:last_int_index)).^2); %Base fit metric off sum of squares difference
%		if cand_fit < best_fit
%			best_fit = cand_fit;
%			best_shift = shift;
%			best_scale = scale;
%		end
%	end
%end
%ones_mean_new = circshift(ones_mean/best_scale,best_shift);

good_ones = max(abs(pn_ones-repmat(ones_mean,[1,size(pn_ones,2)])),[],1) < 7e-3;
ones_mean_new = sum(pn_ones(:,find(good_ones)),2)/sum(good_ones);
good_zeros = max(abs(pn_zeros-repmat(zeros_mean,[1,size(pn_zeros,2)])),[],1) < 7e-3;
zeros_mean_new = sum(pn_zeros(:,find(good_zeros)),2)/sum(good_zeros);
